# frozen_string_literal: true

require_relative "../../model"

class PostgresBranchDisk < Sequel::Model
end

# Table: postgres_branch_disk
# Columns:
#  id                   | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(435)
#  created_at           | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  postgres_resource_id | uuid                     | NOT NULL
#  archil_disk_id       | uuid                     | NOT NULL
#  attached_to_id       | uuid                     |
#  state                | text                     | NOT NULL DEFAULT 'creating'::text
#  target_time          | timestamp with time zone |
#  source_time          | timestamp with time zone |
#  wal_source_branch    | text                     |
#  recovered_at         | timestamp with time zone |
#  owned                | boolean                  | NOT NULL DEFAULT false
#  token_identifier     | text                     |
# Indexes:
#  postgres_branch_disk_pkey                       | PRIMARY KEY btree (id)
#  postgres_branch_disk_attached_to_id_index       | UNIQUE btree (attached_to_id) WHERE attached_to_id IS NOT NULL
#  postgres_branch_disk_postgres_resource_id_index | btree (postgres_resource_id)
# Check constraints:
#  postgres_branch_disk_state_check | (state = ANY (ARRAY['creating'::text, 'ready'::text, 'attached'::text, 'deleting'::text, 'failed'::text]))
# Foreign key constraints:
#  postgres_branch_disk_archil_disk_id_fkey       | (archil_disk_id) REFERENCES postgres_archil_disk(id)
#  postgres_branch_disk_attached_to_id_fkey       | (attached_to_id) REFERENCES postgres_resource(id) ON DELETE SET NULL
#  postgres_branch_disk_postgres_resource_id_fkey | (postgres_resource_id) REFERENCES postgres_resource(id)
