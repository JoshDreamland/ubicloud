# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:postgres_archil_disk) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(723)") # UBID.to_base32_n("pk") => 723
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP

      # disk_id stays NULL until the vendor call returns: the intent row is
      # created before the call so orphaned vendor disks are discoverable.
      column :disk_id, :text, collate: '"C"'

      # The disk's default mount credential, returned exactly once at disk
      # creation. Encrypted at the model layer.
      column :token, :text

      # Identifier of the stored credential when it was minted as a vendor
      # "token user" (a create-time root token has no revocation handle and
      # leaves this NULL). Kept so the credential can be revoked.
      column :token_identifier, :text, collate: '"C"'

      # Archil region name, e.g. "aws-us-east-1".
      column :region, :text, collate: '"C"', null: false
    end

    create_table(:postgres_branch_disk) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(435)") # UBID.to_base32_n("dk") => 435
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP

      # The parent database whose data the disk images. Deleting the parent
      # goes through the model layer, which destroys its disk records first.
      foreign_key :postgres_resource_id, :postgres_resource, type: :uuid, null: false

      # The vendor disk carrying this disk's copy-on-write branch, which is
      # named by this record's ubid. The vendor-disk row must outlive every
      # postgres_branch_disk pointing at it.
      foreign_key :archil_disk_id, :postgres_archil_disk, type: :uuid, null: false

      # The branch instance currently mounting the disk; NULL when detached.
      # A raw delete of the branch resource detaches rather than wedges.
      foreign_key :attached_to_id, :postgres_resource, type: :uuid, on_delete: :set_null

      column :state, :text, collate: '"C"', null: false, default: "creating"

      # The requested point in time; NULL means "now" (cut at creation).
      column :target_time, :timestamptz

      # The parent-data position actually captured, stamped when the vendor
      # branch is cut.
      column :source_time, :timestamptz

      # Vendor branch name of the WAL-source branch backing point-in-time
      # replay: a generated ubid, recorded because vendor branches are
      # undeletable and names must never be reused.
      column :wal_source_branch, :text, collate: '"C"'

      # When a point-in-time disk's targeted recovery promoted. Recovery
      # toward target_time must run exactly once: a reattached disk whose
      # data already promoted past the target adopts it as-is instead.
      column :recovered_at, :timestamptz

      # Whether a branch owns the disk (auto-created at branch create, dies
      # with the branch) rather than the user (detaches and outlives it).
      column :owned, :boolean, null: false, default: false

      # Identifier of the per-VM vendor mount-token user, kept so the
      # credential can be revoked when the mounting VM is destroyed. The
      # token itself is handed only to the VM, never stored here.
      column :token_identifier, :text, collate: '"C"'

      constraint(:postgres_branch_disk_state_check, Sequel.lit("state IN ('creating', 'ready', 'attached', 'deleting', 'failed')"))

      index :postgres_resource_id
      index :attached_to_id, unique: true, where: Sequel.lit("attached_to_id IS NOT NULL")
    end
  end
end
