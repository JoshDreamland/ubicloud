# frozen_string_literal: true

class PostgresServer
  module PrependMethods
    # The pulse result never leaves the monitor process otherwise; persist the
    # latest reading so the respirate exporter can publish it as pg_cp_up, a
    # witness for the instance-down alarm independent of the database VM.
    # reading_rpt resets to 1 on a transition and 1 % 6 == 1, so transitions
    # write immediately and unchanged readings heartbeat every ~30s, keeping
    # at least one point in every one-minute alarm window.
    def check_pulse(session:, previous_pulse:)
      super.tap do |pulse|
        if pulse[:reading_rpt] % 6 == 1
          record_cp_pulse((pulse[:reading] == "up") ? 1 : 0)
        end
      end
    end

    # A VM that is unreachable over SSH never gets a pulse at all: the monitor
    # re-raises here before check_pulse can run. This is the only signal for a
    # fully dead VM, the exact case pg_cp_up exists to detect. The failure
    # recurs every cycle, so the row keeps refreshing while the VM is dead.
    def init_health_monitor_session
      super
    rescue *Sshable::SSH_CONNECTION_ERRORS
      record_cp_pulse(0)
      raise
    end

    def cp_metric_monitor_ds
      POSTGRES_MONITOR_DB[:postgres_int_metric_monitor].where(postgres_server_id: id)
    end

    def before_destroy
      super
      cp_metric_monitor_ds.delete
    end

    def configure_hash
      result = super
      extra_configs = {
        "pg_stat_ch.extra_attributes" => "'#{pg_stat_ch_extra_attributes}'",
        "pg_stat_ch.queue_capacity" => pg_stat_ch_queue_capacity.to_s,
        "pg_stat_ch.string_area_size" => pg_stat_ch_string_area_size.to_s,
        "pg_stat_ch.use_otel" => "on",
        "pg_stat_ch.otel_arrow_passthrough" => "on",
      }
      if resource.flavor == PostgresResource::Flavor::STANDARD
        base_libs = result[:configs]["shared_preload_libraries"].tr("'", "")
        extra_configs["shared_preload_libraries"] = "'#{base_libs},pg_stat_ch'"
      end
      result.merge(configs: result[:configs].merge(extra_configs))
    end

    def read_replica_type
      resource.read_replica_type
    end

    def pg_stat_ch_extra_attributes
      [
        "instance_ubid:#{resource.ubid}",
        "server_ubid:#{ubid}",
        "server_role:#{primary? ? "primary" : "standby"}",
        "read_replica_type:#{read_replica_type}",
        "region:#{resource.location.name}",
        "host_id:#{vm.aws_instance&.instance_id || vm.vm_host_id}",
      ].join(";")
    end

    # Shmem ring buffer for pending events. Power of 2. Sized by vCPUs since
    # event rate scales with query throughput.
    def pg_stat_ch_queue_capacity
      case vm.vcpus
      when 0..2 then 262_144
      when 3..4 then 524_288
      when 5..8 then 1_048_576
      else 2_097_152
      end
    end

    # DSA pool for in-flight event strings. Sized to ~queue_capacity × 200 B
    # so dsa_oom_count tracks queue saturation, not string-pool exhaustion.
    # Value is in MiB.
    def pg_stat_ch_string_area_size
      case vm.vcpus
      when 0..2 then 64
      when 3..4 then 128
      when 5..8 then 256
      else 512
      end
    end

    private

    # The metric write must never break the pulse check it rides on, nor
    # replace the SSH error the monitor classifies; a failed write only
    # costs the metric, and the next reading retries anyway.
    def record_cp_pulse(value)
      return unless Config.postgres_cp_metrics_export_enabled
      POSTGRES_MONITOR_DB[:postgres_int_metric_monitor]
        .insert_conflict(target: [:postgres_server_id, :metric_name], update: {value: Sequel[:excluded][:value], observed_at: Sequel[:excluded][:observed_at]})
        .insert(postgres_server_id: id, metric_name: "pg_cp_up", value:, observed_at: Sequel.function(:now))
    rescue Sequel::Error => ex
      Clog.emit("postgres cp metric write failed", Util.exception_to_hash(ex, into: {ubid:}))
    end
  end
end
