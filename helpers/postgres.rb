# frozen_string_literal: true

class Clover
  def postgres_post(name)
    authorize("Postgres:create", @project)
    fail Validation::ValidationFailed.new({billing_info: "Project doesn't have valid billing information"}) unless @project.has_valid_payment_method?

    flavor = typecast_params.nonempty_str("flavor", PostgresResource.default_flavor)
    size = typecast_params.nonempty_str!("size").gsub("burstable", "hobby")
    storage_size = typecast_params.pos_int("storage_size")
    ha_type = typecast_params.nonempty_str("ha_type", PostgresResource.ha_type_none)
    version = typecast_params.nonempty_str("version", PostgresResource.default_version)
    user_config = typecast_params.Hash("pg_config", {})
    pgbouncer_user_config = typecast_params.Hash("pgbouncer_config", {})
    tags = typecast_params.array(:Hash, "tags", [])
    with_firewall_rules = !typecast_params.bool("restrict_by_default")
    private_subnet_name = typecast_params.nonempty_str("private_subnet_name") if api?
    init_script = typecast_params.nonempty_str("init_script")

    postgres_params = {
      "flavor" => flavor,
      "location" => @location,
      "family" => Option::POSTGRES_SIZE_OPTIONS[size]&.family,
      "size" => size,
      "storage_size" => storage_size,
      "ha_type" => ha_type,
      "version" => version,
    }

    validate_postgres_input(name, postgres_params)

    parsed_size = Option::POSTGRES_SIZE_OPTIONS[postgres_params["size"]]
    requested_standby_count = Option::POSTGRES_HA_OPTIONS[postgres_params["ha_type"]].standby_count
    requested_postgres_vcpu_count = (requested_standby_count + 1) * parsed_size.vcpu_count
    Validation.validate_vcpu_quota(@project, "PostgresVCpu", requested_postgres_vcpu_count)

    validate_postgres_config(version, user_config, pgbouncer_user_config)

    pg = nil
    DB.transaction do
      pg = Prog::Postgres::PostgresResourceNexus.assemble(
        project_id: @project.id,
        location_id: @location.id,
        name:,
        target_vm_size: parsed_size.name,
        target_storage_size_gib: storage_size,
        target_version: version,
        ha_type:,
        with_firewall_rules:,
        flavor:,
        private_subnet_name:,
        user_config:,
        pgbouncer_user_config:,
        tags:,
        init_script:,
      ).subject
      audit_log(pg, "create")
    end
    send_notification_mail_to_partners(pg, current_account.email)

    if api?
      Serializers::Postgres.serialize(pg, {detailed: true})
    else
      flash["notice"] = "'#{name}' will be ready in a few minutes"
      request.redirect pg, "/overview"
    end
  end

  def postgres_list(tags_param: nil)
    dataset = dataset_authorize(@project.postgres_resources_dataset.eager(:timeline, representative_server: [:strand, vm: :vm_storage_volumes]), "Postgres:view").eager(:semaphores, :location, strand: :children)

    if tags_param
      tags_param = tags_param.split(",")
      tags_param = tags_param.map! { |tag| tag.split(":", 2).map(&:strip) }
      tags_param = tags_param.map! { |key, value| {key:, value:} }
      tags_param.each do |tag|
        unless tag[:value]
          fail Validation::ValidationFailed.new({tags: "Invalid tag format. Expected format: key:value"})
        end
      end
      dataset = dataset.where(Sequel.pg_jsonb_op(:tags).contains(tags_param))
    end

    if api?
      dataset = dataset.where(location_id: @location.id) if @location
      paginated_result(dataset, Serializers::Postgres)
    else
      @postgres_databases = dataset.order(:name).all
        .group_by { |r| r.read_replica? ? r[:parent_id] : r[:id] }
        .flat_map { |group_id, rs| rs.sort_by { |r| r[:created_at] } }
      view "postgres/index"
    end
  end

  def send_notification_mail_to_partners(resource, user_email)
    if resource.requires_partner_notification_email? && (email = Config.send(:"postgres_#{resource.flavor}_notification_email"))
      flavor_name = resource.flavor.capitalize
      Util.send_email(email, "New #{flavor_name} Postgres database has been created.",
        greeting: "Hello #{flavor_name} team,",
        body: ["New #{flavor_name} Postgres database has been created.",
          "ID: #{resource.ubid}",
          "Location: #{resource.location.display_name}",
          "Name: #{resource.name}",
          "E-mail: #{user_email}",
          "Instance VM Size: #{resource.target_vm_size}",
          "Instance Storage Size: #{resource.target_storage_size_gib}",
          "HA: #{resource.ha_type}"])
    end
  end

  def postgres_require_customer_firewall!
    unless (fw = @pg.customer_firewall)
      raise CloverError.new(400, "InvalidRequest", "PostgreSQL firewall was deleted, manage firewall rules using an appropriate firewall on the #{@pg.private_subnet.name} private subnet (id: #{@pg.private_subnet.ubid})")
    end

    fw
  end

  def validate_postgres_config(version, user_config, pgbouncer_user_config)
    pg_validator = Validation::PostgresConfigValidator.new(version)
    pg_errors = pg_validator.validation_errors(user_config)

    pgbouncer_validator = Validation::PostgresConfigValidator.new("pgbouncer")
    pgbouncer_errors = pgbouncer_validator.validation_errors(pgbouncer_user_config)

    if pg_errors.any? || pgbouncer_errors.any?
      pg_errors = pg_errors.transform_keys { |key| "pg_config.#{key}" }
      pgbouncer_errors = pgbouncer_errors.transform_keys { |key| "pgbouncer_config.#{key}" }
      raise Validation::ValidationFailed.new(pg_errors.merge(pgbouncer_errors))
    end
  end

  def postgres_status(pg)
    servers = pg.servers(eager: [:strand, :semaphores, :vm])
    primary = servers.find(&:primary?)
    standbys = servers.reject(&:primary?)
    tsdb_client = PostgresServer.victoria_metrics_client

    {
      service: service_status(pg),
      primary: primary && primary_status(pg, primary, tsdb_client),
      standbys: standbys.map { |s| standby_status(pg, s, tsdb_client) },
      connectivity: connectivity_status(pg, primary),
    }
  end

  def service_status(pg)
    timeline = pg.timeline
    {
      ubid: pg.ubid,
      name: pg.name,
      state: pg.display_state,
      ha_type: pg.ha_type,
      version: pg.version,
      vm_size: pg.vm_size,
      storage_size_gib: pg.storage_size_gib,
      location: pg.location.display_name,
      backup: {
        last_started_at: timeline&.latest_backup_started_at&.utc&.iso8601,
        earliest_at: timeline&.cached_earliest_backup_at&.utc&.iso8601,
        configured_interval_hours: timeline&.backup_period_hours,
      },
    }
  end

  def primary_status(pg, server, tsdb_client)
    server_status(pg, server, tsdb_client).merge(
      wal_archival: {
        backlog_count: query_server_metric(tsdb_client, "pg_archival_backlog_count", pg.ubid, "primary")&.to_i,
        metrics_backlog_count: query_server_metric(tsdb_client, "pg_metrics_backlog_count", pg.ubid, "primary")&.to_i,
      }
    )
  end

  def standby_status(pg, server, tsdb_client)
    server_status(pg, server, tsdb_client).merge(
      replication: {
        synchronization_status: server.synchronization_status,
        wal_lag_bytes: (server.compute_lsn_lag_bytes rescue nil),
      }
    )
  end

  def server_status(pg, server, tsdb_client)
    role = server.primary? ? "primary" : "standby"
    state = server.display_state
    status = {
      ubid: server.ubid,
      state: state,
      created_at: server.created_at.utc.iso8601,
      age_seconds: (Time.now - server.created_at).to_i,
      resources: server_resources(tsdb_client, pg.ubid, role),
    }
    status[:strand] = strand_diagnostics(server.strand) if state != "running" && server.strand
    status
  end

  def server_resources(tsdb_client, rid, role)
    {
      load_1m: query_server_metric(tsdb_client, "node_load1", rid, role),
      load_5m: query_server_metric(tsdb_client, "node_load5", rid, role),
      load_15m: query_server_metric(tsdb_client, "node_load15", rid, role),
      memory_used_percent: query_metric(tsdb_client, "sum((1 - (node_memory_MemAvailable_bytes{ubicloud_resource_id=\"#{rid}\", ubicloud_resource_role=\"#{role}\"} / node_memory_MemTotal_bytes{ubicloud_resource_id=\"#{rid}\", ubicloud_resource_role=\"#{role}\"})) * 100)"),
      disk_used_percent: query_metric(tsdb_client, "100 - (sum(node_filesystem_avail_bytes{mountpoint=\"/dat\", ubicloud_resource_id=\"#{rid}\", ubicloud_resource_role=\"#{role}\"} / node_filesystem_size_bytes{mountpoint=\"/dat\", ubicloud_resource_id=\"#{rid}\", ubicloud_resource_role=\"#{role}\"}) * 100)"),
      connections_active: query_server_metric(tsdb_client, "pg_stat_activity_count", rid, role, extra_labels: "state=\"active\"")&.to_i,
      connections_total: query_server_metric(tsdb_client, "pg_stat_activity_count", rid, role)&.to_i,
    }
  end

  def connectivity_status(pg, primary)
    default_config = begin
      primary&.configure_hash || {}
    rescue
      {}
    end
    {
      hostname: pg.hostname,
      port: 5432,
      max_connections: (pg.user_config["max_connections"] || default_config["max_connections"] || "500").to_i,
      reserved_connections: (pg.user_config["superuser_reserved_connections"] || default_config["superuser_reserved_connections"] || "3").to_i,
      connection_string: pg.connection_string,
    }
  end

  def strand_diagnostics(strand)
    frame = strand.stack&.first || {}
    info = {prog: strand.prog, label: strand.label}
    if frame["deadline_target"]
      info[:deadline] = {
        target_label: frame["deadline_target"],
        expires_at: frame["deadline_at"],
        started_at: frame["deadline_start"],
      }.compact
    end
    children = strand.children.select { it.exitval.nil? }
    info[:children] = children.map { |c| strand_diagnostics(c) } unless children.empty?
    info
  end

  def query_metric(tsdb_client, query)
    return nil unless tsdb_client
    tsdb_client.query(query:).first&.dig("value", 1)&.to_f rescue nil
  end

  def query_server_metric(tsdb_client, metric, rid, role, extra_labels: nil)
    labels = "ubicloud_resource_id=\"#{rid}\", ubicloud_resource_role=\"#{role}\""
    labels = "#{extra_labels}, #{labels}" if extra_labels
    query_metric(tsdb_client, "sum(#{metric}{#{labels}})")
  end

  def validate_postgres_input(name, postgres_params)
    Validation.validate_name(name)

    option_tree, option_parents = PostgresResource.generate_postgres_options(@project)

    begin
      Validation.validate_from_option_tree(option_tree, option_parents, postgres_params)
    rescue Validation::ValidationFailed => e
      fail Validation::ValidationFailed.new({size: "Invalid size."}) if e.details.key?(:family)

      raise e
    end

    Validation.validate_postgres_version(postgres_params["version"], postgres_params["flavor"])
  end
end
