# frozen_string_literal: true

class PostgresResource
  module ReadReplicaType
    NONE = "none"
    REGIONAL = "regional"
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
