# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:postgres_int_metric_monitor, unlogged: true) do
      column :postgres_server_id, :uuid, null: false
      column :metric_name, :text, null: false, collate: '"C"'
      column :value, :integer, null: false
      column :observed_at, :timestamptz, null: false
      primary_key [:postgres_server_id, :metric_name]
    end
  end
end
