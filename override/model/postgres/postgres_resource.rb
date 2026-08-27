# frozen_string_literal: true

class PostgresResource
  module ReadReplicaType
    NONE = "none"
    REGIONAL = "regional"
  end

  # How this resource's data volume is backed. instance_storage is the
  # instance-local default every provider supports; archil marks a fork
  # whose data directory is a CoW branch of its parent's mirror disk,
  # mounted over FUSE. The storage_type column's check constraint is the
  # authoritative value list; these constants exist so fork-side code
  # never spells the strings inline.
  module StorageType
    INSTANCE_STORAGE = "instance_storage"
    ARCHIL = "archil"
  end

  module PrependMethods
    def read_replica_type
      read_replica? ? ReadReplicaType::REGIONAL : ReadReplicaType::NONE
    end

    # chc_state tag set. Deactivate flow has started but may not have completed.
    def deactivate_requested?
      (tags || []).any? { it["key"] == "chc_state" && it["value"] == "deactivated" }
    end

    # Both chc_state and chc_deactivated_at tags present. Handler ran end-to-end.
    def deactivated?
      ts = tags || []
      ts.any? { it["key"] == "chc_state" && it["value"] == "deactivated" } &&
        ts.any? { it["key"] == "chc_deactivated_at" }
    end

    def display_state
      # Skip project association fetch when tag is absent (avoids extra query per row in list responses).
      return super unless strand && deactivate_requested? && !destroy_set? && !destroying_set?
      return super unless project.get_ff_chc_postgres_deactivate_lockout
      "deactivated"
    end
  end
end
