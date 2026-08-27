# frozen_string_literal: true

class Prog::Postgres::PostgresResourceNexus
  BILLING_DEACTIVATE_DEADLINE_SECONDS = 3 * 60 * 60

  label :billing_deactivate_suspend
  label :billing_deactivate_wait_backup

  frame_accessor :billing_deactivate_kicked_off_at

  module PrependMethods
    def create_billing_record(billing_rate_id:, amount:, slot:)
      location = postgres_resource.location

      flattened_tags = (postgres_resource.tags || []).each_with_object({}) do |tag, hash|
        hash[tag["key"]] = tag["value"]
      end

      BillingRecord.create(
        project_id: postgres_resource.project_id,
        resource_id: postgres_resource.id,
        resource_name: postgres_resource.name,
        billing_rate_id:,
        amount:,
        resource_tags: Sequel.pg_jsonb({
          **flattened_tags,
          cloud_provider: location.provider,
          region: location.name,
          size: postgres_resource.target_vm_size,
          ha_type: postgres_resource.ha_type,
          flavor: postgres_resource.flavor,
          server_count: postgres_resource.target_server_count,
          storage_size_gib: representative_server.storage_size_gib,
          slot:,
        }),
      )
    end

    def wait
      when_billing_deactivate_set? do
        hop_billing_deactivate_suspend
      end
      if mark_billing_activated_set?
        mark_billing_activated
      elsif mark_billing_deactivated_set?
        mark_billing_deactivated
      end
      super
    end

    def chc_postgres_deactivate_lockout?
      postgres_resource.project.get_ff_chc_postgres_deactivate_lockout
    end

    def update_billing_records
      if chc_postgres_deactivate_lockout? && (postgres_resource.deactivate_requested? || postgres_resource.mark_billing_deactivated_set?)
        decr_update_billing_records
        decr_initial_provisioning
        hop_wait
      end
      super
    end

    # Two-phase tag write. chc_state up front so a concurrent configure
    # respects lockout; chc_deactivated_at last as the commit point (retry-safe:
    # crash mid-handler → next tick sees `!deactivated?` and re-runs).
    # Flag OFF: single-tag legacy path, no lockout.
    def mark_billing_deactivated
      unless chc_postgres_deactivate_lockout?
        unless postgres_resource.deactivate_requested?
          tags = (postgres_resource.tags || []).reject { it["key"] == "chc_state" } +
            [{"key" => "chc_state", "value" => "deactivated"}]
          postgres_resource.update(tags: Sequel.pg_jsonb(tags))
        end
        postgres_resource.active_billing_records.each(&:finalize)
        postgres_resource.read_replicas.each(&:incr_mark_billing_deactivated)
        decr_mark_billing_deactivated
        return
      end
      if postgres_resource.deactivated?
        decr_mark_billing_deactivated
        return
      end
      unless postgres_resource.deactivate_requested?
        phase1 = (postgres_resource.tags || []).reject { it["key"] == "chc_state" } +
          [{"key" => "chc_state", "value" => "deactivated"}]
        postgres_resource.update(tags: Sequel.pg_jsonb(phase1))
      end
      postgres_resource.servers.sort_by { it.is_representative ? 1 : 0 }.each(&:apply_lockout)
      postgres_resource.active_billing_records.each(&:finalize)
      postgres_resource.read_replicas.each(&:incr_mark_billing_deactivated)
      phase3 = (postgres_resource.tags || []).reject { it["key"] == "chc_deactivated_at" } +
        [{"key" => "chc_deactivated_at", "value" => Time.now.utc.iso8601}]
      postgres_resource.update(tags: Sequel.pg_jsonb(phase3))
      decr_mark_billing_deactivated
    end

    # Drain deactivate BEFORE tag-clear: a queued deactivate that landed after
    # ours would re-lock the just-reactivated row.
    def mark_billing_activated
      postgres_resource.incr_update_billing_records
      postgres_resource.servers.each(&:incr_configure)
      decr_mark_billing_deactivated
      tags = (postgres_resource.tags || []).reject { it["key"] == "chc_state" || it["key"] == "chc_deactivated_at" }
      postgres_resource.update(tags: Sequel.pg_jsonb(tags))
      decr_mark_billing_activated
    end

    def billing_deactivate_suspend
      decr_billing_deactivate
      register_deadline("destroy", BILLING_DEACTIVATE_DEADLINE_SECONDS)

      # Finalize here: hop_destroy below skips before_run's finalize (no destroy semaphore).
      postgres_resource.active_billing_records.each(&:finalize)

      # Shared-timeline resources (read replicas, PITR restores before
      # switch_to_new_timeline) must not run backup/lifecycle changes on the
      # parent's bucket.
      timeline = postgres_resource.timeline
      parent = postgres_resource.parent
      hop_destroy if parent && timeline == parent.timeline

      if timeline.leader.nil?
        # No leader (failover / unhealthy primary). Nap; 3h deadline pages if it never recovers.
        Clog.emit("billing_deactivate_no_leader_at_kick_off", {pg_ubid: postgres_resource.ubid})
        nap 30
      end

      postgres_resource.read_replicas.each(&:incr_billing_deactivate)

      postgres_resource.servers.sort_by { it.is_representative ? 1 : 0 }.each do |server|
        server.apply_lockout
      end

      # Kickoff timestamp — wait_backup must accept only a backup completed AFTER lockout.
      self.billing_deactivate_kicked_off_at = Time.now.utc.iso8601
      timeline.incr_take_backup_for_converge
      hop_billing_deactivate_wait_backup
    end

    def billing_deactivate_wait_backup
      kicked_off_at = Time.parse(billing_deactivate_kicked_off_at)
      latest_completed = postgres_resource.timeline.backups.map(&:last_modified).max
      nap 60 if latest_completed.nil? || latest_completed < kicked_off_at

      postgres_resource.timeline.set_lifecycle_policy(expiration_days: Config.billing_deactivate_retention_days)
      hop_destroy
    end
  end
end
