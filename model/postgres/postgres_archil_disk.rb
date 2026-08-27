# frozen_string_literal: true

require_relative "../../model"

class PostgresArchilDisk < Sequel::Model
end

# Table: postgres_archil_disk
# Columns:
#  id               | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(723)
#  created_at       | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  disk_id          | text                     |
#  token            | text                     |
#  token_identifier | text                     |
#  region           | text                     | NOT NULL
# Indexes:
#  postgres_archil_disk_pkey | PRIMARY KEY btree (id)
# Referenced By:
#  postgres_branch_disk | postgres_branch_disk_archil_disk_id_fkey | (archil_disk_id) REFERENCES postgres_archil_disk(id)
