# frozen_string_literal: true

class Clover
  # Server semaphores triggered for each upgrade-testing kind.
  POSTGRES_UPGRADE_TESTING_SEMAPHORES = {
    "rhizome" => ["install_rhizome"].freeze,
    "telemetry" => ["configure_metrics", "configure_logs"].freeze,
  }.freeze

  # Resolves the target servers for an upgrade request.
  def pg_testing_servers_for_upgrade(pg)
    ubids = typecast_params.array(:nonempty_str, "servers")
    return pg.servers if ubids.nil? || ubids.empty?

    by_ubid = pg.servers.to_h { [it.ubid, it] }
    ubids.uniq.map do |ubid|
      by_ubid[ubid] || raise(CloverError.new(404, "ResourceNotFound", "Server #{ubid} not found in this Postgres resource"))
    end
  end

  # Rolls the upgrade semaphores for upgrade_type across the target servers via a
  # TriggerServerUpgrade strand: standbys first, then the primary, each
  # converging before the next. Poll the convergence endpoint to track progress.
  def pg_testing_trigger_upgrade(pg, servers, upgrade_type)
    semaphores = POSTGRES_UPGRADE_TESTING_SEMAPHORES.fetch(upgrade_type)
    Strand.create(
      prog: "Postgres::TriggerServerUpgrade",
      label: "start",
      stack: [{"subject_id" => pg.id, "server_ids" => servers.map(&:id), "semaphores" => semaphores}],
      parent_id: pg.id,
    )

    pg_testing_write_upgrade_audit_log(pg, upgrade_type, servers)
    no_audit_log

    ordered = servers.reject(&:is_representative) + servers.select(&:is_representative)
    {servers: ordered.map(&:ubid), semaphores_triggered: semaphores}
  end

  # Reports, per server, the git commit recorded in rhizome_installation versus
  # the control plane's current commit
  def pg_testing_rhizome_status(pg)
    expected_commit = Config.git_commit_hash
    servers = pg.servers
    installs = DB[:rhizome_installation].where(id: servers.map(&:vm_id), folder: "postgres").to_hash(:id)

    server_statuses = servers.map do |s|
      ri = installs[s.vm_id]
      {
        server: s.ubid,
        representative: s.is_representative,
        commit: ri && ri[:commit],
        installed_at: ri && ri[:installed_at].utc.iso8601,
        up_to_date: !ri.nil? && ri[:commit] == expected_commit,
      }
    end

    {
      folder: "postgres",
      expected_commit:,
      up_to_date: server_statuses.any? && server_statuses.all? { it[:up_to_date] },
      servers: server_statuses,
    }
  end

  private

  def pg_testing_write_upgrade_audit_log(pg, upgrade_type, servers)
    DB[:audit_log].returning(nil).insert(
      project_id: @project.id,
      ubid_type: ::PostgresResource.ubid_type,
      action: "upgrade_#{upgrade_type}",
      subject_id: current_account.id,
      object_ids: Sequel.pg_array([pg.id] + servers.map(&:id), :uuid),
    )
  end
end
