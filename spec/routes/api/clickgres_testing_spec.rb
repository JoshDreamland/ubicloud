# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "clickgres-testing" do
  let(:user) { create_account }
  let(:project) { project_with_default_policy(user) }

  before do
    login_api
    postgres_project = Project.create(name: "default")
    allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)
    ENV["ENABLE_FAILURE_INJECTION"] = "true"
  end

  after do
    ENV.delete("ENABLE_FAILURE_INJECTION")
  end

  def create_pg(name)
    Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: project.id,
      location_id: Location::HETZNER_FSN1_ID,
      name:,
      target_vm_size: "standard-2",
      target_storage_size_gib: 128,
    ).subject
  end

  # Temporarily replaces _cmd on the SSH module for the duration of the block,
  # restoring the original method in ensure to prevent leaking across examples.
  def with_stub_sshable(cmds = [], raise_error: nil)
    original = NetSsh::WarnUnsafe::Sshable.instance_method(:_cmd)
    NetSsh::WarnUnsafe::Sshable.define_method(:_cmd) do |cmd, **|
      cmds << cmd
      raise raise_error if raise_error
      ""
    end
    # inject-failure deliberately issues SSH from the route (test tooling gated
    # by ENABLE_FAILURE_INJECTION); bypass the route-spec SSH guard for the block
    # while keeping the _cmd stub so placeholder substitution still happens.
    route_spec, Thread.current[:route_spec] = Thread.current[:route_spec], nil
    yield cmds
  ensure
    Thread.current[:route_spec] = route_spec
    NetSsh::WarnUnsafe::Sshable.define_method(:_cmd, original)
  end

  def inject_failure_path(pg_or_name)
    name_or_id = pg_or_name.is_a?(String) ? pg_or_name : pg_or_name.name
    "/project/#{project.ubid}/clickgres-testing/#{name_or_id}/inject-failure"
  end

  def convergence_path(pg_or_name)
    name_or_id = pg_or_name.is_a?(String) ? pg_or_name : pg_or_name.name
    "/project/#{project.ubid}/clickgres-testing/#{name_or_id}/convergence"
  end

  def upgrade_path(pg_or_name, kind)
    name_or_id = pg_or_name.is_a?(String) ? pg_or_name : pg_or_name.name
    "/project/#{project.ubid}/clickgres-testing/#{name_or_id}/upgrade-#{kind}"
  end

  def rhizome_status_path(pg_or_name)
    name_or_id = pg_or_name.is_a?(String) ? pg_or_name : pg_or_name.name
    "/project/#{project.ubid}/clickgres-testing/#{name_or_id}/rhizome-status"
  end

  def record_rhizome(pg, commit:, folder: "postgres", digest: "ignored-digest")
    RhizomeInstallation.dataset.insert(
      id: pg.representative_server.vm_id, folder:, commit:, digest:, installed_at: Time.now,
    )
  end

  describe "POST /project/:project_id/clickgres-testing/:pg_name_or_id/inject-failure" do
    it "returns 403 when failure injection is disabled" do
      ENV.delete("ENABLE_FAILURE_INJECTION")
      pg = create_pg("test-pg-disabled")
      post inject_failure_path(pg), {failure_type: "pg_restart"}.to_json
      expect(last_response.status).to eq(403)
      expect(JSON.parse(last_response.body).dig("error", "message")).to eq("Failure injection is not enabled for this deployment")
    end

    it "returns 404 for nonexistent postgres resource" do
      post inject_failure_path("nonexistent"), {failure_type: "pg_restart"}.to_json
      expect(last_response.status).to eq(404)
    end

    it "rejects missing failure_type at schema validation" do
      pg = create_pg("test-pg-missing")
      expect {
        post inject_failure_path(pg), "{}"
      }.to raise_error(Committee::InvalidRequest, /missing required parameters: failure_type/)
    end

    it "rejects invalid failure_type at schema validation" do
      pg = create_pg("test-pg-invalid")
      expect {
        post inject_failure_path(pg), {failure_type: "invalid"}.to_json
      }.to raise_error(Committee::InvalidRequest, /isn't part of the enum/)
    end

    it "injects pg_restart failure" do
      pg = create_pg("test-pg-restart")
      version = pg.representative_server.version
      with_stub_sshable do |cmds|
        post inject_failure_path(pg), {failure_type: "pg_restart"}.to_json
        expect(last_response.status).to eq(204)
        expect(last_response.body).to be_empty
        expect(cmds).to include("sudo pg_ctlcluster #{version} main restart")
      end
    end

    it "propagates SSH errors for pg_restart" do
      pg = create_pg("test-pg-restart-fail")
      with_stub_sshable(raise_error: Errno::ECONNREFUSED) do
        expect {
          post inject_failure_path(pg), {failure_type: "pg_restart"}.to_json
        }.to raise_error(Errno::ECONNREFUSED)
      end
    end

    it "handles SSH errors gracefully for os_shutdown" do
      pg = create_pg("test-pg-shutdown")
      with_stub_sshable(raise_error: Errno::ECONNRESET) do
        post inject_failure_path(pg), {failure_type: "os_shutdown"}.to_json
        expect(last_response.status).to eq(204)
      end
    end

    it "injects pg_service_stop failure" do
      pg = create_pg("test-pg-svc-stop")
      version = pg.representative_server.version
      with_stub_sshable do |cmds|
        post inject_failure_path(pg), {failure_type: "pg_service_stop"}.to_json
        expect(last_response.status).to eq(204)
        expect(cmds).to include("sudo pg_ctlcluster #{version} main stop -m smart")
      end
    end

    it "looks up postgres resource by UBID" do
      pg = create_pg("test-pg-ubid")
      with_stub_sshable do
        post "/project/#{project.ubid}/clickgres-testing/#{pg.ubid}/inject-failure",
          {failure_type: "pg_restart"}.to_json
        expect(last_response.status).to eq(204)
      end
    end

    it "writes an audit_log row tagged with the failure type" do
      pg = create_pg("test-pg-audit")
      with_stub_sshable do
        expect {
          post inject_failure_path(pg), {failure_type: "pg_restart"}.to_json
        }.to change { DB[:audit_log].where(action: "inject_failure_pg_restart").count }.by(1)
        expect(last_response.status).to eq(204)
      end
    end

    it "returns 400 when the resource has no representative server" do
      pg = create_pg("test-pg-no-server")
      # Demote all servers so PostgresResource#representative_server returns nil.
      # allow_any_instance_of doesn't work in frozen mode (the model class is frozen).
      pg.servers_dataset.update(is_representative: false)
      post inject_failure_path(pg), {failure_type: "pg_restart"}.to_json
      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body).dig("error", "message"))
        .to eq("No representative server found for this database")
    end
  end

  describe "POST /project/:project_id/clickgres-testing/:pg_name_or_id/upgrade-rhizome" do
    it "returns 404 for nonexistent postgres resource" do
      post upgrade_path("nonexistent", "rhizome"), {}.to_json
      expect(last_response.status).to eq(404)
    end

    it "rolls install_rhizome across all servers standby-first when no list is given" do
      pg = create_pg("test-pg-rhizome")
      standby = create_postgres_server(resource: pg, is_representative: false)
      primary = pg.representative_server

      post upgrade_path(pg, "rhizome"), {}.to_json
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["servers"]).to eq([standby.ubid, primary.ubid])
      expect(body["semaphores_triggered"]).to eq(["install_rhizome"])

      strand = pg.strand.children_dataset.first(prog: "Postgres::TriggerServerUpgrade")
      expect(strand).not_to be_nil
      expect(strand.stack.first["server_ids"]).to contain_exactly(primary.id, standby.id)
      expect(strand.stack.first["semaphores"]).to eq(["install_rhizome"])
    end

    it "limits the rollout to the given servers list" do
      pg = create_pg("test-pg-rhizome-subset")
      standby = create_postgres_server(resource: pg, is_representative: false)

      post upgrade_path(pg, "rhizome"), {servers: [standby.ubid]}.to_json
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["servers"]).to eq([standby.ubid])
      strand = pg.strand.children_dataset.first(prog: "Postgres::TriggerServerUpgrade")
      expect(strand.stack.first["server_ids"]).to eq([standby.id])
    end

    it "treats an empty servers list as all servers" do
      pg = create_pg("test-pg-rhizome-empty")
      post upgrade_path(pg, "rhizome"), {servers: []}.to_json
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["servers"]).to eq([pg.representative_server.ubid])
    end

    it "deduplicates repeated server UBIDs" do
      pg = create_pg("test-pg-rhizome-dup")
      server = pg.representative_server

      post upgrade_path(pg, "rhizome"), {servers: [server.ubid, server.ubid]}.to_json
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["servers"]).to eq([server.ubid])
      strand = pg.strand.children_dataset.first(prog: "Postgres::TriggerServerUpgrade")
      expect(strand.stack.first["server_ids"]).to eq([server.id])
    end

    it "returns 404 when a given server does not belong to the resource" do
      pg = create_pg("test-pg-rhizome-badsrv")
      post upgrade_path(pg, "rhizome"), {servers: ["stnotarealserver000000000"]}.to_json
      expect(last_response.status).to eq(404)
    end

    it "writes an audit_log row tagged upgrade_rhizome" do
      pg = create_pg("test-pg-rhizome-audit")
      expect {
        post upgrade_path(pg, "rhizome"), {}.to_json
      }.to change { DB[:audit_log].where(action: "upgrade_rhizome").count }.by(1)
      expect(last_response.status).to eq(200)
    end

    it "looks up postgres resource by UBID" do
      pg = create_pg("test-pg-rhizome-ubid")
      post "/project/#{project.ubid}/clickgres-testing/#{pg.ubid}/upgrade-rhizome", {}.to_json
      expect(last_response.status).to eq(200)
    end
  end

  describe "POST /project/:project_id/clickgres-testing/:pg_name_or_id/upgrade-telemetry" do
    it "returns 404 for nonexistent postgres resource" do
      post upgrade_path("nonexistent", "telemetry"), {}.to_json
      expect(last_response.status).to eq(404)
    end

    it "rolls configure_metrics and configure_logs across the resource's servers" do
      pg = create_pg("test-pg-telemetry")

      post upgrade_path(pg, "telemetry"), {}.to_json
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["servers"]).to eq([pg.representative_server.ubid])
      expect(body["semaphores_triggered"]).to eq(["configure_metrics", "configure_logs"])

      strand = pg.strand.children_dataset.first(prog: "Postgres::TriggerServerUpgrade")
      expect(strand.stack.first["semaphores"]).to eq(["configure_metrics", "configure_logs"])
    end

    it "writes an audit_log row tagged upgrade_telemetry" do
      pg = create_pg("test-pg-telemetry-audit")
      expect {
        post upgrade_path(pg, "telemetry"), {}.to_json
      }.to change { DB[:audit_log].where(action: "upgrade_telemetry").count }.by(1)
      expect(last_response.status).to eq(200)
    end

    it "looks up postgres resource by UBID" do
      pg = create_pg("test-pg-telemetry-ubid")
      post "/project/#{project.ubid}/clickgres-testing/#{pg.ubid}/upgrade-telemetry", {}.to_json
      expect(last_response.status).to eq(200)
    end
  end

  describe "GET /project/:project_id/clickgres-testing/:pg_name_or_id/rhizome-status" do
    it "returns 404 for nonexistent postgres resource" do
      get rhizome_status_path("nonexistent")
      expect(last_response.status).to eq(404)
    end

    it "reports up_to_date when the recorded commit matches the current control plane commit" do
      allow(Config).to receive(:git_commit_hash).and_return("commit-current")
      pg = create_pg("test-pg-rhz-ok")
      record_rhizome(pg, commit: "commit-current")

      get rhizome_status_path(pg)
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["folder"]).to eq("postgres")
      expect(body["expected_commit"]).to eq("commit-current")
      expect(body["up_to_date"]).to be(true)
      expect(body["servers"].length).to eq(1)
      expect(body["servers"][0]).to include(
        "server" => pg.representative_server.ubid,
        "representative" => true,
        "commit" => "commit-current",
        "up_to_date" => true,
      )
      expect(body["servers"][0]["installed_at"]).to be_a(String)
    end

    it "reports not up_to_date when a server's recorded commit is stale" do
      allow(Config).to receive(:git_commit_hash).and_return("commit-current")
      pg = create_pg("test-pg-rhz-stale")
      record_rhizome(pg, commit: "commit-old")

      get rhizome_status_path(pg)
      body = JSON.parse(last_response.body)
      expect(body["up_to_date"]).to be(false)
      expect(body["servers"][0]["up_to_date"]).to be(false)
    end

    it "reports null fields and not up_to_date when rhizome was never installed" do
      pg = create_pg("test-pg-rhz-missing")

      get rhizome_status_path(pg)
      body = JSON.parse(last_response.body)
      expect(body["up_to_date"]).to be(false)
      expect(body["servers"][0]).to include(
        "commit" => nil, "installed_at" => nil, "up_to_date" => false,
      )
    end

    it "does not write an audit_log row" do
      pg = create_pg("test-pg-rhz-audit")
      expect { get rhizome_status_path(pg) }
        .not_to change { DB[:audit_log].count }
      expect(last_response.status).to eq(200)
    end
  end

  describe "GET /project/:project_id/clickgres-testing/:pg_name_or_id/convergence" do
    it "is reachable even when failure injection is disabled" do
      ENV.delete("ENABLE_FAILURE_INJECTION")
      pg = create_pg("test-pg-conv-no-gate")
      get convergence_path(pg)
      expect(last_response.status).to eq(200)
    end

    it "returns 404 for nonexistent postgres resource" do
      get convergence_path("nonexistent")
      expect(last_response.status).to eq(404)
    end

    it "reports not converged for a freshly assembled resource" do
      pg = create_pg("test-pg-conv-fresh")
      get convergence_path(pg)
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["converged"]).to be(false)
      # A freshly assembled resource hasn't reached `wait` on its servers yet,
      # so at minimum servers_not_ready should be reported.
      expect(body["reasons"]).to include("servers_not_ready")
    end

    it "reports converged when all checks pass" do
      pg = create_pg("test-pg-conv-ok")
      # Drive real state instead of stubs (allow_any_instance_of doesn't work
      # in frozen mode): move all strands to `wait` and clear assemble-time
      # semaphores like initial_provisioning.
      strand_ids = pg.servers.map(&:id) + [pg.id]
      DB[:strand].where(id: strand_ids).update(label: "wait")
      DB[:semaphore].where(strand_id: strand_ids).delete

      get convergence_path(pg)
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body).to eq("converged" => true, "reasons" => [], "pending_semaphores" => [])
    end

    it "lists each failed check in reasons" do
      pg = create_pg("test-pg-conv-failing")
      # Leave strands at their initial (non-wait) labels → servers_not_ready.
      # incr_recycle_unavailable_server → needs_recycling? → needs_convergence?
      # incr_unplanned_take_over → taking_over? → ongoing_failover?
      # Both also count as pending semaphores.
      server = pg.representative_server
      server.incr_recycle_unavailable_server
      server.incr_unplanned_take_over

      get convergence_path(pg)
      body = JSON.parse(last_response.body)
      expect(body["converged"]).to be(false)
      expect(body["reasons"]).to include("needs_convergence", "servers_not_ready", "ongoing_failover", "pending_semaphores")
    end

    it "reports pending_semaphores excluding checkup, use_different_az, and use_old_walg_command" do
      pg = create_pg("test-pg-conv-sems")
      strand_ids = pg.servers.map(&:id) + [pg.id]
      DB[:strand].where(id: strand_ids).update(label: "wait")
      DB[:semaphore].where(strand_id: strand_ids).delete

      server = pg.representative_server
      server.incr_restart
      server.incr_checkup
      pg.incr_use_different_az
      pg.incr_use_old_walg_command

      get convergence_path(pg)
      body = JSON.parse(last_response.body)
      expect(body["converged"]).to be(false)
      expect(body["reasons"]).to eq(["pending_semaphores"])
      expect(body["pending_semaphores"]).to eq(["restart"])
    end

    it "reports pending_upgrade_rollout while a TriggerServerUpgrade strand is active" do
      pg = create_pg("test-pg-conv-rollout")
      strand_ids = pg.servers.map(&:id) + [pg.id]
      DB[:strand].where(id: strand_ids).update(label: "wait")
      DB[:semaphore].where(strand_id: strand_ids).delete
      Strand.create(
        prog: "Postgres::TriggerServerUpgrade", label: "wait_primary", parent_id: pg.id,
        stack: [{"subject_id" => pg.id, "server_ids" => pg.servers.map(&:id), "semaphores" => ["install_rhizome"]}],
      )

      get convergence_path(pg)
      body = JSON.parse(last_response.body)
      expect(body["converged"]).to be(false)
      expect(body["reasons"]).to eq(["pending_upgrade_rollout"])
    end

    it "looks up postgres resource by UBID" do
      pg = create_pg("test-pg-conv-ubid")
      get "/project/#{project.ubid}/clickgres-testing/#{pg.ubid}/convergence"
      expect(last_response.status).to eq(200)
    end

    it "does not write an audit_log row" do
      pg = create_pg("test-pg-conv-audit")
      expect { get convergence_path(pg) }
        .not_to change { DB[:audit_log].where(Sequel.lit("? = ANY(object_ids)", pg.id)).count }
      expect(last_response.status).to eq(200)
    end
  end
end
