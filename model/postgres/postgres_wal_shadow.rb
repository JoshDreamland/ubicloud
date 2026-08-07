# frozen_string_literal: true

require_relative "../../model"

class PostgresWalShadow < Sequel::Model
  many_to_one :project
  many_to_one :postgres_resource
  many_to_one :vm, read_only: true
  one_to_one :strand, key: :id, read_only: true

  plugin ResourceMethods, encrypted_columns: %i[base_ch_config api_ch_config]
  plugin SemaphoreMethods, :update_config, :destroy

  DEFAULT_STORAGE_SIZE_GIB = 40

  # Size walshadow to 1/4th of source vCPU; durable state prefers the
  # non-instance-store family, but only when it's billable at the location
  def self.default_vm_size(postgres_resource, data_on_boot_volume)
    source = vm_size_option(postgres_resource.target_vm_size)
    family = source.family
    if data_on_boot_volume
      base = family.delete_suffix("d")
      if base != family && Option::VmSizes.any? { it.family == base && it.arch == source.arch } &&
          BillingRate.from_resource_properties("VmVCpu", base, postgres_resource.location.name)
        family = base
      end
    end
    family_sizes = Option::VmSizes.select { it.family == family && it.arch == source.arch }
    vcpus = [source.vcpus / 4, family_sizes.map(&:vcpus).min].max
    family_sizes.select { it.vcpus <= vcpus }.max_by(&:vcpus).name
  end

  def self.vm_size_option(vm_size)
    Option::VmSizes.find { it.name == vm_size }
  end

  def instance_store_path
    data_on_boot_volume ? "/var/lib/walshadow/out" : "/var/lib/walshadow"
  end

  def display_location
    postgres_resource.display_location
  end

  def path
    "#{postgres_resource.path}/wal-shadow"
  end

  def display_state
    return "deleting" if destroy_set? || destroying_set? || strand.nil?
    (strand.label == "wait") ? "running" : "creating"
  end

  def api_config_hash
    api_ch_config ? JSON.parse(api_ch_config) : {}
  end

  def api_config_toml
    ChConfig.render_toml(api_config_hash)
  end

  def merge_api_config!(config)
    update(api_ch_config: JSON.generate(ChConfig.deep_merge(api_config_hash, config)))
  end

  def unset_api_config!(keys)
    update(api_ch_config: JSON.generate(ChConfig.delete_paths(api_config_hash, keys)))
  end
end

# Table: postgres_wal_shadow
# Columns:
#  id                   | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(921)
#  created_at           | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  project_id           | uuid                     | NOT NULL
#  postgres_resource_id | uuid                     | NOT NULL
#  vm_id                | uuid                     |
#  git_ref              | text                     | NOT NULL DEFAULT 'main'::text
#  data_on_boot_volume  | boolean                  | NOT NULL DEFAULT true
#  base_ch_config       | text                     | NOT NULL
#  api_ch_config        | text                     |
#  status               | jsonb                    |
#  status_at            | timestamp with time zone |
# Indexes:
#  postgres_wal_shadow_pkey                     | PRIMARY KEY btree (id)
#  postgres_wal_shadow_postgres_resource_id_key | UNIQUE btree (postgres_resource_id)
# Foreign key constraints:
#  postgres_wal_shadow_postgres_resource_id_fkey | (postgres_resource_id) REFERENCES postgres_resource(id)
#  postgres_wal_shadow_project_id_fkey           | (project_id) REFERENCES project(id)
#  postgres_wal_shadow_vm_id_fkey                | (vm_id) REFERENCES vm(id) ON DELETE SET NULL
