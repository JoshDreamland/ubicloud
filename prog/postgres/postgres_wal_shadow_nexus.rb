# frozen_string_literal: true

class Prog::Postgres::PostgresWalShadowNexus < Prog::Base
  subject_is :postgres_wal_shadow

  frame_accessor :boot_image, :vm_size, :storage_size_gib

  def self.assemble(postgres_resource_id, ch_config:, boot_image:, git_ref: "main", vm_size: nil, storage_size_gib: nil, data_on_boot_volume: true)
    postgres_resource = PostgresResource[postgres_resource_id]
    fail "No existing PostgresResource" unless postgres_resource
    fail "walshadow already exists for this PostgresResource" if postgres_resource.postgres_wal_shadow

    vm_size ||= PostgresWalShadow.default_vm_size(postgres_resource, data_on_boot_volume)
    # ephemeral state stores data on the fixed-size instance store, so a boot volume
    # size is meaningless; size the instance-store family instead
    if storage_size_gib && !data_on_boot_volume
      fail Validation::ValidationFailed.new({storage_size_gib: "cannot be set when data is on the instance store"})
    end
    storage_size_gib ||= PostgresWalShadow::DEFAULT_STORAGE_SIZE_GIB
    Validation.validate_vm_size(vm_size, PostgresWalShadow.vm_size_option(vm_size)&.arch)

    # git_ref is interpolated into a shell git checkout on the VM; reject unsafe refs
    unless git_ref.match?(/\A[a-zA-Z0-9][a-zA-Z0-9._\/-]*\z/) && !git_ref.include?("..")
      fail Validation::ValidationFailed.new({git_ref: "must be a valid git ref (branch, tag, or commit sha)"})
    end
    begin
      parsed_ch_config = ChConfig.parse(ch_config)
    rescue ChConfig::ParseError
      fail Validation::ValidationFailed.new({ch_config: "must be valid TOML"})
    end
    unless parsed_ch_config.key?("ch")
      fail Validation::ValidationFailed.new({ch_config: "must contain a [ch] config section"})
    end

    DB.transaction do
      postgres_wal_shadow = PostgresWalShadow.create(
        project_id: postgres_resource.project_id,
        postgres_resource_id:,
        git_ref:,
        base_ch_config: ch_config,
        data_on_boot_volume:,
      )
      # child of the resource strand: destroy fans out here and reaps the VM before subnet teardown
      Strand.create_with_id(postgres_wal_shadow, prog: "Postgres::PostgresWalShadowNexus", label: "start", parent_id: postgres_resource_id, stack: [{"boot_image" => boot_image, "vm_size" => vm_size, "storage_size_gib" => storage_size_gib}])
    end
  end

  # operator escape hatch to replace the base config; the API path mutates api_ch_config
  def self.update_config(postgres_wal_shadow, ch_config)
    postgres_wal_shadow.update(base_ch_config: ch_config)
    postgres_wal_shadow.incr_update_config
  end

  def postgres_resource
    postgres_wal_shadow.postgres_resource
  end

  def vm
    postgres_wal_shadow.vm
  end

  def pg_version
    postgres_resource.representative_server.version
  end

  def before_run
    when_destroy_set? do
      hop_destroy unless %w[destroy wait_vm_destroyed].include?(strand.label)
    end
  end

  label def start
    # bound the whole provision so a stuck step pages instead of retrying invisibly
    register_deadline("wait", 30 * 60)
    wal_level = postgres_resource.representative_server.run_query("SHOW wal_level")
    fail "walshadow requires wal_level=logical, got #{wal_level}; set via user_config and restart servers first" unless wal_level == "logical"
    hop_create_vm
  end

  label def create_vm
    vm_st = Prog::Vm::Nexus.assemble_with_sshable(
      postgres_resource.project_id,
      sshable_unix_user: "ubi",
      location_id: postgres_resource.location_id,
      name: "#{postgres_resource.ubid}-pw",
      size: vm_size,
      arch: PostgresWalShadow.vm_size_option(vm_size).arch,
      boot_image:,
      private_subnet_id: postgres_resource.private_subnet_id,
      enable_ip4: true,
      use_separate_management_nic: postgres_resource.location.aws?,
      storage_volumes: [{encrypted: true, size_gib: storage_size_gib}],
    )
    postgres_wal_shadow.update(vm_id: vm_st.id)
    hop_wait_vm
  end

  label def wait_vm
    nap 5 unless vm.strand.label == "wait"
    hop_attach_s3_policy
  end

  # AttachRolePolicy is eventually consistent; the deps install and build that
  # follow are the slack before the daemon first reads the bucket.
  label def attach_s3_policy
    postgres_wal_shadow.attach_s3_policy_if_needed
    hop_bootstrap_rhizome
  end

  label def bootstrap_rhizome
    bud Prog::BootstrapRhizome, {"target_folder" => "postgres", "subject_id" => vm.id, "user" => "ubi"}
    hop_wait_bootstrap_rhizome
  end

  label def wait_bootstrap_rhizome
    reap(:mount_instance_store, nap: 5)
  end

  # out/ rides instance store when the family ships it; shadow-data + spill join
  # it only when data_on_boot_volume is off, else everything stays on the boot volume
  label def mount_instance_store
    case vm.sshable.d_check("mount_walshadow_instance_store")
    when "Succeeded"
      vm.sshable.d_clean("mount_walshadow_instance_store")
      hop_install_deps
    when "Failed", "NotStarted"
      vm.sshable.d_run("mount_walshadow_instance_store", "sudo", "postgres/bin/mount-walshadow-instance-store", postgres_wal_shadow.instance_store_path)
    end
    nap 5
  end

  label def install_deps
    case vm.sshable.d_check("install_walshadow_deps")
    when "Succeeded"
      vm.sshable.d_clean("install_walshadow_deps")
      hop_build
    when "Failed", "NotStarted"
      vm.sshable.d_run("install_walshadow_deps", "bash", "-c", deps_script)
    end
    nap 15
  end

  label def build
    case vm.sshable.d_check("build_walshadow")
    when "Succeeded"
      vm.sshable.d_clean("build_walshadow")
      hop_install
    when "Failed", "NotStarted"
      vm.sshable.d_run("build_walshadow", "bash", "-c", build_script)
    end
    nap 15
  end

  label def install
    case vm.sshable.d_check("install_walshadow")
    when "Succeeded"
      vm.sshable.d_clean("install_walshadow")
      write_unit_file
      hop_write_config
    when "Failed", "NotStarted"
      vm.sshable.d_run("install_walshadow", "sudo", "postgres/bin/install-walshadow", pg_version)
    end
    nap 15
  end

  label def write_config
    write_base_config
    write_backup_config
    write_api_config
    hop_start_daemon
  end

  label def start_daemon
    vm.sshable.cmd("sudo systemctl daemon-reload && sudo systemctl enable --now walshadow")
    hop_wait
  end

  label def wait
    when_update_config_set? do
      decr_update_config
      write_base_config
      write_backup_config
      write_api_config
      vm.sshable.cmd("sudo systemctl reload walshadow")
    end

    refresh_status
    nap 30
  end

  label def destroy
    decr_destroy
    reap(nap: 5) do
      vm&.incr_destroy
      hop_wait_vm_destroyed
    end
  end

  label def wait_vm_destroyed
    nap 5 if vm
    postgres_wal_shadow.destroy
    pop "walshadow destroyed"
  end

  # base config is operator-owned; the API fragment lives in ch-config.d/50-api.toml
  def write_base_config
    vm.sshable.cmd("sudo install -d /etc/walshadow && sudo install -d -o postgres -g postgres /etc/walshadow/ch-config.d && sudo install -m 600 -o postgres -g postgres /dev/null /etc/walshadow/ch-config.toml && sudo tee /etc/walshadow/ch-config.toml > /dev/null", stdin: postgres_wal_shadow.base_ch_config, log: false)
  end

  def write_backup_config
    vm.sshable.cmd("sudo install -m 600 -o postgres -g postgres /dev/null /etc/walshadow/ch-config.d/10-backup.toml && sudo tee /etc/walshadow/ch-config.d/10-backup.toml > /dev/null", stdin: postgres_wal_shadow.backup_config_toml)
  end

  # API-owned fragment, deep-merged over base by the daemon in filename order
  def write_api_config
    vm.sshable.cmd("sudo install -m 600 -o postgres -g postgres /dev/null /etc/walshadow/ch-config.d/50-api.toml && sudo tee /etc/walshadow/ch-config.d/50-api.toml > /dev/null", stdin: postgres_wal_shadow.api_config_toml, log: false)
  end

  # written here, not via the install script, so the source password never lands
  # in the daemonizer's stored command. mode 600, tee preserves perms
  def write_unit_file
    vm.sshable.cmd("sudo install -m 600 /dev/null /etc/systemd/system/walshadow.service && sudo tee /etc/systemd/system/walshadow.service > /dev/null", stdin: unit_file, log: false)
  end

  # best-effort status poll; keeps the stale snapshot rather than crash-looping
  # when the daemon is starting or the VM is briefly unreachable
  def refresh_status
    output = vm.sshable.cmd("sudo -u postgres walshadow-stream ctl status")
    postgres_wal_shadow.update(status: ChConfig.parse_status_toml(output), status_at: Time.now)
  rescue Sshable::SshError, *Sshable::SSH_CONNECTION_ERRORS => e
    Clog.emit("walshadow status refresh failed", {postgres_wal_shadow: postgres_wal_shadow.ubid, error: e.message})
  end

  def deps_script
    # create_main_cluster=false stops pgdg from spawning a cluster on 5432
    <<~SCRIPT
      set -ueo pipefail
      sudo apt-get update
      sudo DEBIAN_FRONTEND=noninteractive apt-get -y install build-essential git liblz4-dev libzstd-dev curl ca-certificates postgresql-common
      sudo install -d /etc/postgresql-common/createcluster.d
      echo create_main_cluster=false | sudo tee /etc/postgresql-common/createcluster.d/no-main.conf
      sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
      sudo DEBIAN_FRONTEND=noninteractive apt-get -y install postgresql-#{pg_version} postgresql-server-dev-#{pg_version}
      curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
    SCRIPT
  end

  def build_script
    # full clone + checkout so git_ref may be branch, tag, or sha
    <<~SCRIPT
      set -ueo pipefail
      rm -rf walshadow-src
      git clone --recurse-submodules -q https://github.com/ClickHouse/walshadow walshadow-src
      git -C walshadow-src checkout -q #{postgres_wal_shadow.git_ref.shellescape}
      cd walshadow-src
      ~/.cargo/bin/cargo build --release --bin walshadow-stream
    SCRIPT
  end

  # PATH lets the shadow spawn find pg_ctl/initdb; RuntimeDirectory gives the daemon
  # /run/walshadow for its control socket; '+' ExecStartPre runs as root to recreate
  # state dirs after an instance-store wipe (empty shadow-data re-bootstraps)
  def unit_file
    <<~UNIT
      [Unit]
      Description=walshadow catalog-replay daemon
      Wants=network-online.target
      After=network-online.target

      [Service]
      User=postgres
      RuntimeDirectory=walshadow
      Environment=PATH=/usr/lib/postgresql/#{pg_version}/bin:/usr/bin:/bin
      Environment=WALSHADOW_SOURCE_HOST=#{postgres_resource.representative_server.vm.private_ipv4_string}
      Environment=WALSHADOW_SOURCE_PASSWORD=#{postgres_resource.superuser_password}
      ExecStartPre=+/usr/bin/install -d -o postgres -g postgres /var/lib/walshadow /var/lib/walshadow/out /var/lib/walshadow/spill
      ExecStartPre=+/usr/bin/install -d -o postgres -g postgres -m 700 /var/lib/walshadow/shadow-data
      ExecStart=/usr/local/bin/walshadow-run
      ExecReload=/bin/kill -HUP $MAINPID
      Restart=on-failure
      KillMode=control-group

      [Install]
      WantedBy=multi-user.target
    UNIT
  end
end
