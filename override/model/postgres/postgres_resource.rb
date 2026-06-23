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
  end
end
