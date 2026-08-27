# frozen_string_literal: true

require_relative "../../model"

# An Archil disk backing postgres data. The row is created as an intent
# record before the vendor call, so disk_id is NULL until the disk exists;
# a NULL disk_id past its creation window marks an orphan to reconcile.
class PostgresArchilDisk < Sequel::Model
  one_to_many :postgres_branch_disks, key: :archil_disk_id, read_only: true

  plugin ResourceMethods, encrypted_columns: [:token]
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
