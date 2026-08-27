# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_resource) do
      add_column :storage_type, :text, collate: '"C"', null: false, default: "instance_storage"
      add_constraint(:storage_type_check, Sequel.lit("storage_type IN ('instance_storage', 'archil')"))
    end
  end
end
