# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:postgres_wal_shadow) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(921)") # pw ubid type
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      foreign_key :project_id, :project, type: :uuid, null: false
      # one walshadow per source postgres
      foreign_key :postgres_resource_id, :postgres_resource, type: :uuid, null: false, unique: true
      foreign_key :vm_id, :vm, type: :uuid, on_delete: :set_null
      # TODO remove git_ref when walshadow AMI is created
      column :git_ref, :text, collate: '"C"', null: false, default: "main"

      # data_on_boot_volume: true keeps shadow-data + spill on the durable boot
      # volume (survives instance-store loss); false places them on instance store.
      column :data_on_boot_volume, :boolean, null: false, default: true

      # base_ch_config: full ch-config.toml set at create; api_ch_config: JSON overlay
      # set via the wal-shadow API, deep-merged over base. Both encrypted (CH password).
      column :base_ch_config, :text, null: false
      column :api_ch_config, :text

      # status: last `ctl status` snapshot the strand refreshes each nap.
      column :status, :jsonb
      column :status_at, :timestamptz
    end
  end
end
