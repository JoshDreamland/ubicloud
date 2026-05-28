# frozen_string_literal: true

class Prog::Postgres::PostgresTimelineNexus < Prog::Base
  subject_is :postgres_timeline

  def self.assemble(location_id:, parent_id: nil)
    if parent_id && (parent = PostgresTimeline[parent_id]).nil?
      fail "No existing parent"
    end

    unless (location = Location[location_id])
      fail "No existing location"
    end

    DB.transaction do
      postgres_timeline = PostgresTimeline.create(parent_id:, location_id: location.id, backup_period_hours: parent&.backup_period_hours || 24)
      if postgres_timeline.generate_blob_storage_credentials?
        postgres_timeline.update(access_key: SecureRandom.hex(16), secret_key: SecureRandom.hex(32))
      end
      Strand.create_with_id(postgres_timeline, prog: "Postgres::PostgresTimelineNexus", label: "start")
    end
  end

  label def start
    if postgres_timeline.blob_storage
      postgres_timeline.setup_blob_storage
      hop_setup_bucket
    end

    hop_wait_leader
  end

  label def setup_bucket
    nap 1 if postgres_timeline.aws? && !Config.aws_postgres_iam_access && !aws_access_key_is_available?

    postgres_timeline.create_bucket
    postgres_timeline.set_lifecycle_policy
    hop_wait_leader
  end

  label def wait_leader
    leader = postgres_timeline.leader
    nap 5 if leader.nil? || leader.strand.label != "wait" || !leader.walg_credentials_ready?
    hop_wait
  end

  label def wait
    dependent = PostgresServer[timeline_id: postgres_timeline.id]
    backups = postgres_timeline.backups
    if dependent.nil? && backups.empty? && Time.now - postgres_timeline.created_at > 10 * 24 * 60 * 60
      Clog.emit("Self-destructing timeline as no leader or backups are present and it is older than 10 days", postgres_timeline)
      hop_destroy
    end

    nap 20 * 60 if postgres_timeline.blob_storage.nil?

    # For the purpose of missing backup pages, we act like the very first backup
    # is taken at the creation, which ensures that we would get a page if and only
    # if no backup is taken for 2 days.
    latest_backup_completed_at = backups.map(&:last_modified).max || postgres_timeline.created_at
    if postgres_timeline.leader && latest_backup_completed_at < Time.now - 2 * 24 * 60 * 60 # 2 days
      Prog::PageNexus.assemble("Missing backup at #{postgres_timeline}!", ["MissingBackup", postgres_timeline.id], postgres_timeline.ubid)
    else
      Page.from_tag_parts("MissingBackup", postgres_timeline.id)&.incr_resolve
    end

    if postgres_timeline.need_backup?
      hop_take_backup
    end

    nap 20 * 60
  end

  label def take_backup
    # It is possible that we already started backup but crashed before saving
    # the state to database. Since backup taking is an expensive operation,
    # we check if backup is truly needed.
    if postgres_timeline.need_backup?
      d_command = NetSsh.command("sudo postgres/bin/take-backup :version", version: postgres_timeline.leader.version)
      postgres_timeline.leader.vm.sshable.cmd("common/bin/daemonizer :d_command take_postgres_backup", d_command:)
      postgres_timeline.latest_backup_started_at = Time.now
      postgres_timeline.save_changes
      # Hop into await_backup so we can emit a structured completion event
      # (including failures) once the daemonizer reaches a terminal state.
      hop_await_backup
    end

    hop_wait
  end

  # Polls the backup daemonizer until it reaches a terminal state, then
  # emits one "Postgres backup completed" Clog event and hops back to wait.
  #
  # Tradeoffs versus emitting completion events from wait:
  # - For the duration of the backup, the strand sits in this label and
  #   does not run wait's other per-cycle reconciliation (missing-backup
  #   page handling, self-destruct check, etc.). The 2-day missing-backup
  #   pager is unaffected because latest_backup_started_at is fresh, but
  #   any other work added to wait would be paused while a backup runs.
  # - SSH check cadence on the leader rises from once per ~20 min (wait's
  #   nap interval) to once per 30 s for the duration of the backup.
  # - The strand is not synchronously blocked: the daemonizer call remains
  #   fire-and-forget and we yield between polls via `nap`.
  #
  # Benefit over the wait-side alternative: this label can observe Failed
  # status explicitly. A failed backup leaves no S3 sentinel, so wait-side
  # observation can only emit on success.
  label def await_backup
    case postgres_timeline.leader.vm.sshable.cmd("common/bin/daemonizer --check take_postgres_backup")
    when "Succeeded"
      emit_backup_completion("Succeeded")
      hop_wait
    when "Failed"
      emit_backup_completion("Failed")
      hop_wait
    when "InProgress", "NotStarted"
      nap 30
    else
      emit_backup_completion("Unknown")
      hop_wait
    end
  end

  def emit_backup_completion(status)
    started = postgres_timeline.latest_backup_started_at
    duration_seconds = started ? Time.now - started : nil
    # await_backup is only entered immediately after take_backup, which
    # requires postgres_timeline.leader to be present. The &. is defensive
    # against teardown races (leader removed between take_backup and our
    # first poll); a nil resource_id is preferable to a NoMethodError.
    resource_id = postgres_timeline.leader&.resource&.ubid
    Clog.emit("Postgres backup completed", [{status:, duration_seconds:, resource_id:}, postgres_timeline])
  end

  label def destroy
    decr_destroy
    postgres_timeline.destroy_blob_storage if postgres_timeline.blob_storage
    postgres_timeline.destroy
    pop "postgres timeline is deleted"
  end

  def aws_access_key_is_available?
    iam_client.list_access_keys(user_name: postgres_timeline.ubid).access_key_metadata.any? { it.access_key_id == postgres_timeline.access_key }
  end

  def iam_client
    postgres_timeline.location.location_credential_aws.iam_client
  end
end
