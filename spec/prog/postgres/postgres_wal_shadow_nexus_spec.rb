# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Prog::Postgres::PostgresWalShadowNexus do
  subject(:nx) { described_class.new(st) }

  let(:project) { Project.create(name: "test-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }
  let(:postgres_resource) { create_postgres_resource(project:, location_id:) }
  let(:postgres_server) { create_postgres_server(resource: postgres_resource) }
  let(:st) { described_class.assemble(postgres_resource.id, ch_config: "[ch]\nurl = \"h\"\n", boot_image: "ami-0123") }
  let(:ws) { st.subject }
  let(:sshable) {
    postgres_server
    nx.postgres_resource.representative_server.vm.sshable
  }
  let(:vm_strand) { Prog::Vm::Nexus.assemble_with_sshable(project.id, sshable_unix_user: "ubi", location_id:) }
  let(:vm_sshable) { nx.vm.sshable }
  let(:ctl_status_cmd) { "sudo -u postgres walshadow-stream ctl status" }
  let(:base_config_cmd) { "sudo install -d /etc/walshadow && sudo install -d -o postgres -g postgres /etc/walshadow/ch-config.d && sudo install -m 600 -o postgres -g postgres /dev/null /etc/walshadow/ch-config.toml && sudo tee /etc/walshadow/ch-config.toml > /dev/null" }
  let(:api_config_cmd) { "sudo install -m 600 -o postgres -g postgres /dev/null /etc/walshadow/ch-config.d/50-api.toml && sudo tee /etc/walshadow/ch-config.d/50-api.toml > /dev/null" }

  describe ".assemble" do
    it "creates a postgres_wal_shadow model and strand pointed at it" do
      expect(st.prog).to eq "Postgres::PostgresWalShadowNexus"
      expect(st.label).to eq "start"
      expect(st.parent_id).to eq postgres_resource.id
      expect(st.stack.first).to eq({"boot_image" => "ami-0123", "vm_size" => "standard-2", "storage_size_gib" => 40})
      expect(st.id).to eq ws.id
      expect(ws).to be_a PostgresWalShadow
      expect(ws.project_id).to eq project.id
      expect(ws.postgres_resource_id).to eq postgres_resource.id
      expect(ws.base_ch_config).to eq "[ch]\nurl = \"h\"\n"
      expect(ws.git_ref).to eq "main"
      expect(ws.data_on_boot_volume).to be true
    end

    it "steps down a tier and drops the instance-store 'd' when the base family is billable" do
      postgres_resource.update(target_vm_size: "m8gd.16xlarge")
      allow(BillingRate).to receive(:from_resource_properties).with("VmVCpu", "m8g", postgres_resource.location.name).and_return({})
      expect(described_class.assemble(postgres_resource.id, ch_config: "[ch]\n", boot_image: "ami").stack.first["vm_size"]).to eq "m8g.4xlarge"
    end

    it "keeps the instance-store family when the base isn't billable at the location" do
      postgres_resource.update(target_vm_size: "m8gd.16xlarge")
      expect(described_class.assemble(postgres_resource.id, ch_config: "[ch]\n", boot_image: "ami").stack.first["vm_size"]).to eq "m8gd.4xlarge"
    end

    it "keeps the instance-store 'd' family for ephemeral state" do
      postgres_resource.update(target_vm_size: "m8gd.16xlarge")
      expect(described_class.assemble(postgres_resource.id, ch_config: "[ch]\n", boot_image: "ami", data_on_boot_volume: false).stack.first["vm_size"]).to eq "m8gd.4xlarge"
    end

    it "accepts explicit size and storage for durable state" do
      st = described_class.assemble(postgres_resource.id, ch_config: "[ch]\n", boot_image: "ami", vm_size: "m8g.xlarge", storage_size_gib: 60, data_on_boot_volume: true)
      expect(st.stack.first["vm_size"]).to eq "m8g.xlarge"
      expect(st.stack.first["storage_size_gib"]).to eq 60
      expect(st.subject.data_on_boot_volume).to be true
    end

    it "defaults the boot volume for ephemeral state" do
      st = described_class.assemble(postgres_resource.id, ch_config: "[ch]\n", boot_image: "ami", vm_size: "m8gd.xlarge", data_on_boot_volume: false)
      expect(st.stack.first["storage_size_gib"]).to eq PostgresWalShadow::DEFAULT_STORAGE_SIZE_GIB
      expect(st.subject.data_on_boot_volume).to be false
    end

    it "rejects storage_size_gib when data is on the instance store" do
      expect {
        described_class.assemble(postgres_resource.id, ch_config: "[ch]\n", boot_image: "ami", vm_size: "m8gd.xlarge", storage_size_gib: 60, data_on_boot_volume: false)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: storage_size_gib"
    end

    it "rejects an unknown size" do
      expect {
        described_class.assemble(postgres_resource.id, ch_config: "[ch]\n", boot_image: "ami", vm_size: "m9gd.nope")
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: size"
    end

    it "rejects a git ref with shell metacharacters" do
      expect {
        described_class.assemble(postgres_resource.id, ch_config: "[ch]\n", boot_image: "ami", git_ref: "main; rm -rf /")
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: git_ref"
    end

    it "rejects ch_config without a [ch] table" do
      expect {
        described_class.assemble(postgres_resource.id, ch_config: "url = \"h\"\n", boot_image: "ami")
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: ch_config"
    end

    it "rejects ch_config that is not valid TOML" do
      expect {
        described_class.assemble(postgres_resource.id, ch_config: "[ch\nurl = ", boot_image: "ami")
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: ch_config"
    end

    it "fails without existing resource" do
      expect {
        described_class.assemble(SecureRandom.uuid, ch_config: "", boot_image: "")
      }.to raise_error RuntimeError, "No existing PostgresResource"
    end

    it "fails when a walshadow already exists" do
      st
      expect {
        described_class.assemble(postgres_resource.id, ch_config: "", boot_image: "")
      }.to raise_error RuntimeError, "walshadow already exists for this PostgresResource"
    end
  end

  describe ".update_config" do
    it "replaces base_ch_config and increments update_config" do
      described_class.update_config(ws, "[ch]\nurl = \"h2\"\n")
      expect(ws.reload.base_ch_config).to eq "[ch]\nurl = \"h2\"\n"
      expect(Semaphore.where(strand_id: ws.id, name: "update_config").count).to eq 1
    end
  end

  describe "#before_run" do
    it "hops to destroy when destroy semaphore is set" do
      nx.incr_destroy
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop while destroying" do
      nx.incr_destroy
      st.update(label: "destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end
  end

  describe "#start" do
    it "hops when wal_level is logical" do
      expect(sshable).to receive(:_cmd).with("PGOPTIONS='-c statement_timeout=60s' psql -U postgres -t --csv -v 'ON_ERROR_STOP=1'", stdin: "SHOW wal_level").and_return("logical\n")
      expect { nx.start }.to hop("create_vm")
    end

    it "fails otherwise" do
      expect(sshable).to receive(:_cmd).with("PGOPTIONS='-c statement_timeout=60s' psql -U postgres -t --csv -v 'ON_ERROR_STOP=1'", stdin: "SHOW wal_level").and_return("replica\n")
      expect { nx.start }.to raise_error RuntimeError, "walshadow requires wal_level=logical, got replica; set via user_config and restart servers first"
    end
  end

  describe "#create_vm" do
    it "assembles VM in resource's subnet and hops" do
      subnet = PrivateSubnet.create(
        name: "pg-subnet", project_id: project.id, location_id:,
        net4: "172.0.0.0/26", net6: "fdfa:b5aa:14a3:4a3d::/64",
      )
      postgres_resource.update(private_subnet_id: subnet.id)
      refresh_frame(nx, new_values: {"vm_size" => "m8gd.large", "storage_size_gib" => 60})
      vm_strand
      expect(Prog::Vm::Nexus).to receive(:assemble_with_sshable).with(
        project.id,
        sshable_unix_user: "ubi",
        location_id:,
        name: "#{postgres_resource.ubid}-pw",
        size: "m8gd.large",
        arch: "arm64",
        boot_image: "ami-0123",
        private_subnet_id: subnet.id,
        enable_ip4: true,
        use_separate_management_nic: false,
        storage_volumes: [{encrypted: true, size_gib: 60}],
      ).and_return(vm_strand)
      expect { nx.create_vm }.to hop("wait_vm")
      expect(ws.reload.vm_id).to eq vm_strand.id
    end
  end

  describe "#wait_vm" do
    before { ws.update(vm_id: vm_strand.id) }

    it "naps until vm is ready" do
      expect { nx.wait_vm }.to nap(5)
    end

    it "hops when vm is ready" do
      vm_strand.update(label: "wait")
      expect { nx.wait_vm }.to hop("bootstrap_rhizome")
    end
  end

  describe "#bootstrap_rhizome" do
    it "buds BootstrapRhizome for the postgres folder against vm and hops" do
      ws.update(vm_id: vm_strand.id)
      expect { nx.bootstrap_rhizome }.to hop("wait_bootstrap_rhizome")
      expect(st.children.map { |c| [c.prog, c.stack.first] }).to eq [
        ["BootstrapRhizome", {"subject_id" => vm_strand.id, "target_folder" => "postgres", "user" => "ubi"}],
      ]
    end
  end

  describe "#wait_bootstrap_rhizome" do
    it "hops when bootstrap is complete" do
      expect { nx.wait_bootstrap_rhizome }.to hop("mount_instance_store")
    end

    it "naps while bootstrap is in progress" do
      Strand.create(parent_id: st.id, prog: "BootstrapRhizome", label: "start", stack: [{}], lease: Time.now + 10)
      expect { nx.wait_bootstrap_rhizome }.to nap(5)
    end
  end

  describe "#mount_instance_store" do
    before { ws.update(vm_id: vm_strand.id) }

    it "cleans the daemonizer unit and hops when succeeded" do
      expect(vm_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check mount_walshadow_instance_store").and_return("Succeeded")
      expect(vm_sshable).to receive(:_cmd).with("common/bin/daemonizer2 clean mount_walshadow_instance_store")
      expect { nx.mount_instance_store }.to hop("install_deps")
    end

    ["Failed", "NotStarted"].each do |state|
      it "runs the mount script when #{state}" do
        expect(vm_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check mount_walshadow_instance_store").and_return(state)
        expect(vm_sshable).to receive(:_cmd).with("common/bin/daemonizer2 run mount_walshadow_instance_store #{["sudo", "postgres/bin/mount-walshadow-instance-store", "/var/lib/walshadow/out"].shelljoin}", stdin: nil, log: true)
        expect { nx.mount_instance_store }.to nap(5)
      end
    end

    it "naps while in progress" do
      expect(vm_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check mount_walshadow_instance_store").and_return("InProgress")
      expect { nx.mount_instance_store }.to nap(5)
    end
  end

  describe "#install_deps" do
    before { ws.update(vm_id: vm_strand.id) }

    it "cleans daemonizer unit and hops when succeeded" do
      expect(vm_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check install_walshadow_deps").and_return("Succeeded")
      expect(vm_sshable).to receive(:_cmd).with("common/bin/daemonizer2 clean install_walshadow_deps")
      expect { nx.install_deps }.to hop("build")
    end

    ["Failed", "NotStarted"].each do |state|
      it "starts install when #{state}" do
        postgres_server
        expect(vm_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check install_walshadow_deps").and_return(state)
        expect(vm_sshable).to receive(:_cmd).with("common/bin/daemonizer2 run install_walshadow_deps #{["bash", "-c", nx.deps_script].shelljoin}", stdin: nil, log: true)
        expect { nx.install_deps }.to nap(15)
      end
    end

    it "naps while in progress" do
      expect(vm_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check install_walshadow_deps").and_return("InProgress")
      expect { nx.install_deps }.to nap(15)
    end
  end

  describe "#deps_script" do
    it "pins pgdg packages to source major and disables main cluster" do
      postgres_server
      expect(nx.deps_script).to eq <<~SCRIPT
        set -ueo pipefail
        sudo apt-get update
        sudo DEBIAN_FRONTEND=noninteractive apt-get -y install build-essential git liblz4-dev libzstd-dev curl ca-certificates postgresql-common
        sudo install -d /etc/postgresql-common/createcluster.d
        echo create_main_cluster=false | sudo tee /etc/postgresql-common/createcluster.d/no-main.conf
        sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
        sudo DEBIAN_FRONTEND=noninteractive apt-get -y install postgresql-17 postgresql-server-dev-17
        curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
      SCRIPT
    end
  end

  describe "#build" do
    before { ws.update(vm_id: vm_strand.id) }

    it "cleans daemonizer unit and hops when succeeded" do
      expect(vm_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check build_walshadow").and_return("Succeeded")
      expect(vm_sshable).to receive(:_cmd).with("common/bin/daemonizer2 clean build_walshadow")
      expect { nx.build }.to hop("install")
    end

    it "starts build when not started" do
      expect(vm_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check build_walshadow").and_return("NotStarted")
      expect(vm_sshable).to receive(:_cmd).with("common/bin/daemonizer2 run build_walshadow #{["bash", "-c", nx.build_script].shelljoin}", stdin: nil, log: true)
      expect { nx.build }.to nap(15)
    end

    it "naps while in progress" do
      expect(vm_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check build_walshadow").and_return("InProgress")
      expect { nx.build }.to nap(15)
    end

    it "clones ref and builds release binary" do
      expect(nx.build_script).to eq <<~SCRIPT
        set -ueo pipefail
        rm -rf walshadow-src
        git clone --recurse-submodules -q https://github.com/ClickHouse/walshadow walshadow-src
        git -C walshadow-src checkout -q main
        cd walshadow-src
        ~/.cargo/bin/cargo build --release --bin walshadow-stream
      SCRIPT
    end
  end

  describe "#install" do
    before do
      postgres_server
      ws.update(vm_id: vm_strand.id)
    end

    it "writes the unit and hops when succeeded" do
      expect(vm_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check install_walshadow").and_return("Succeeded")
      expect(vm_sshable).to receive(:_cmd).with("common/bin/daemonizer2 clean install_walshadow")
      expect(vm_sshable).to receive(:_cmd).with("sudo install -m 600 /dev/null /etc/systemd/system/walshadow.service && sudo tee /etc/systemd/system/walshadow.service > /dev/null", stdin: nx.unit_file, log: false)
      expect { nx.install }.to hop("write_config")
    end

    ["Failed", "NotStarted"].each do |state|
      it "runs the install script when #{state}" do
        expect(vm_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check install_walshadow").and_return(state)
        expect(vm_sshable).to receive(:_cmd).with("common/bin/daemonizer2 run install_walshadow #{["sudo", "postgres/bin/install-walshadow", nx.pg_version].shelljoin}", stdin: nil, log: true)
        expect { nx.install }.to nap(15)
      end
    end

    it "naps while in progress" do
      expect(vm_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check install_walshadow").and_return("InProgress")
      expect { nx.install }.to nap(15)
    end
  end

  describe "#unit_file" do
    it "bakes representative server address, password, and pg PATH" do
      postgres_server
      expect(nx.unit_file).to eq <<~UNIT
        [Unit]
        Description=walshadow catalog-replay daemon
        Wants=network-online.target
        After=network-online.target

        [Service]
        User=postgres
        RuntimeDirectory=walshadow
        Environment=PATH=/usr/lib/postgresql/17/bin:/usr/bin:/bin
        Environment=WALSHADOW_SOURCE_HOST=#{nx.postgres_resource.representative_server.vm.private_ipv4_string}
        Environment=WALSHADOW_SOURCE_PASSWORD=dummy-password
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

  describe "#write_config" do
    it "writes base and api configs and hops" do
      ws.update(vm_id: vm_strand.id)
      expect(vm_sshable).to receive(:_cmd).with(base_config_cmd, stdin: "[ch]\nurl = \"h\"\n", log: false)
      expect(vm_sshable).to receive(:_cmd).with(api_config_cmd, stdin: "", log: false)
      expect { nx.write_config }.to hop("start_daemon")
    end
  end

  describe "#start_daemon" do
    it "enables and starts unit" do
      ws.update(vm_id: vm_strand.id)
      expect(vm_sshable).to receive(:_cmd).with("sudo systemctl daemon-reload && sudo systemctl enable --now walshadow")
      expect { nx.start_daemon }.to hop("wait")
    end
  end

  describe "#wait" do
    before { ws.update(vm_id: vm_strand.id) }

    it "refreshes status and naps" do
      expect(vm_sshable).to receive(:_cmd).with(ctl_status_cmd).and_return("paused = false\n")
      expect { nx.wait }.to nap(30)
      expect(ws.reload.status).to eq({"paused" => false})
    end

    it "rewrites configs and reloads daemon on update_config" do
      nx.incr_update_config
      expect(vm_sshable).to receive(:_cmd).with(base_config_cmd, stdin: "[ch]\nurl = \"h\"\n", log: false)
      expect(vm_sshable).to receive(:_cmd).with(api_config_cmd, stdin: "", log: false)
      expect(vm_sshable).to receive(:_cmd).with("sudo systemctl reload walshadow")
      expect(vm_sshable).to receive(:_cmd).with(ctl_status_cmd).and_return("paused = false\n")
      expect { nx.wait }.to nap(30)
      expect(Semaphore.where(strand_id: ws.id, name: "update_config")).to be_empty
    end
  end

  describe "#refresh_status" do
    before { ws.update(vm_id: vm_strand.id) }

    it "caches the parsed control-socket status" do
      expect(vm_sshable).to receive(:_cmd).with(ctl_status_cmd).and_return("paused = true\nrows_synced = 5\nlag_seconds = 1.5\n")
      nx.refresh_status
      expect(ws.reload.status).to eq({"paused" => true, "rows_synced" => 5, "lag_seconds" => 1.5})
      expect(ws.status_at).not_to be_nil
    end

    it "keeps the stale snapshot when the control socket errors" do
      expect(vm_sshable).to receive(:_cmd).with(ctl_status_cmd).and_raise(Sshable::SshError.new(ctl_status_cmd, "", "ERR not running", 1, nil))
      expect(Clog).to receive(:emit).with("walshadow status refresh failed", hash_including(:postgres_wal_shadow, :error))
      nx.refresh_status
      expect(ws.reload.status).to be_nil
    end
  end

  describe "#destroy" do
    it "flags vm for destruction and hops" do
      ws.update(vm_id: vm_strand.id)
      nx.incr_destroy
      expect { nx.destroy }.to hop("wait_vm_destroyed")
      expect(Semaphore.where(strand_id: vm_strand.id, name: "destroy").count).to eq 1
      expect(Semaphore.where(strand_id: ws.id, name: "destroy")).to be_empty
    end

    it "hops without vm" do
      expect { nx.destroy }.to hop("wait_vm_destroyed")
    end

    it "naps while children are still running" do
      Strand.create(parent_id: st.id, prog: "BootstrapRhizome", label: "start", stack: [{}], lease: Time.now + 10)
      expect { nx.destroy }.to nap(5)
    end
  end

  describe "#wait_vm_destroyed" do
    it "naps while vm exists" do
      ws.update(vm_id: vm_strand.id)
      expect { nx.wait_vm_destroyed }.to nap(5)
    end

    it "destroys the postgres_wal_shadow row and pops once vm is gone" do
      ws_id = ws.id
      expect { nx.wait_vm_destroyed }.to exit({"msg" => "walshadow destroyed"})
      expect(PostgresWalShadow[ws_id]).to be_nil
    end

    # vm_id FK is ON DELETE SET NULL so the vm nexus can delete the vm row while
    # this strand still references it; otherwise teardown deadlocks (the vm delete
    # is FK-blocked, and wait_vm_destroyed never sees the vm go away).
    it "has ON DELETE SET NULL on the vm_id foreign key" do
      fk = DB.foreign_key_list(:postgres_wal_shadow).find { it[:columns] == [:vm_id] }
      expect(fk[:on_delete]).to eq :set_null
    end
  end
end
