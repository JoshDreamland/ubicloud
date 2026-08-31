# frozen_string_literal: true

Sequel.migration do
  change do
    # A provider-managed volume is created before the VM that mounts it, so it
    # needs an identity of its own: the provider call is keyed by this row's
    # ubid, which is what makes a lost response recoverable rather than an
    # orphaned volume. Its own table also keeps provider-specific configuration
    # out of vm_storage_volume, which is otherwise a metal table.
    #
    # A volume is destroyed with the VM that mounts it. Detaching and reusing a
    # volume across VM replacements would save the restore from backup, but
    # nothing does that yet, so nothing here pretends to.
    create_table(:network_volume) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(699)") # nv ubid type
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP

      foreign_key :location_id, :location, type: :uuid, null: false

      # The provider's identifier: an EBS volume id, a GCP disk name. NULL until
      # the provider call returns; the row is created first so a lost response
      # cannot orphan a volume, since creation is keyed by this row's ubid.
      # Neutral rather than per-provider so the generic attach, detach and
      # destroy paths need no dispatch to read it.
      column :provider_id, :text, collate: '"C"'

      column :size_gib, :bigint, null: false
      constraint(:network_volume_size_positive, Sequel.lit("size_gib > 0"))
    end

    # Provider-specific configuration, keyed by the shared row, as with
    # location and location_credential_aws.
    create_table(:aws_volume) do
      foreign_key :id, :network_volume, type: :uuid, primary_key: true, on_delete: :cascade
      column :volume_type, :text, collate: '"C"', null: false
      column :provisioned_iops, :integer
      column :provisioned_throughput_mibps, :integer

      constraint(:aws_volume_type_check, Sequel.lit("volume_type IN ('gp3', 'io2')"))
      constraint(:aws_volume_iops_positive, Sequel.lit("provisioned_iops IS NULL OR provisioned_iops > 0"))
      constraint(:aws_volume_throughput_positive, Sequel.lit("provisioned_throughput_mibps IS NULL OR provisioned_throughput_mibps > 0"))
    end

    # io2 derives throughput from IOPS, so only gp3 and hyperdisk-balanced
    # accept a throughput; the per-provider tables keep that asymmetry local.
    create_table(:gcp_volume) do
      foreign_key :id, :network_volume, type: :uuid, primary_key: true, on_delete: :cascade
      column :volume_type, :text, collate: '"C"', null: false
      column :provisioned_iops, :integer
      column :provisioned_throughput_mibps, :integer

      constraint(:gcp_volume_type_check, Sequel.lit("volume_type IN ('hyperdisk-balanced')"))
      constraint(:gcp_volume_iops_positive, Sequel.lit("provisioned_iops IS NULL OR provisioned_iops > 0"))
      constraint(:gcp_volume_throughput_positive, Sequel.lit("provisioned_throughput_mibps IS NULL OR provisioned_throughput_mibps > 0"))
    end

    # The attachment. Metal volumes keep their existing shape and reference
    # nothing; only provider-managed volumes point at a network_volume row.
    # A volume is mounted by at most one VM: EBS multi-attach is io2-only and
    # needs a cluster-aware filesystem, and ext4 is not one.
    alter_table(:vm_storage_volume) do
      add_foreign_key :network_volume_id, :network_volume, type: :uuid, unique: true
    end
  end
end
