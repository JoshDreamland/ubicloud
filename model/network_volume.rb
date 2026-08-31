# frozen_string_literal: true

require_relative "../model"

class NetworkVolume < Sequel::Model
  module VolumeType
    GP3 = "gp3"
    IO2 = "io2"
    HYPERDISK_BALANCED = "hyperdisk-balanced"
  end

  # Ratio limits constrain IOPS by size and throughput by IOPS. A nil
  # throughput range means the provider derives throughput from IOPS; nil ratio
  # fields mean that ratio is unconstrained.
  Limits = Data.define(:iops, :throughput_mibps, :max_iops_per_gib, :max_mibps_per_iops, :min_mibps_per_iops, :default_iops, :default_throughput_mibps) do
    def configurable_throughput? = !throughput_mibps.nil?
  end
  LIMITS = {
    VolumeType::GP3 => Limits.new(3000..80_000, 125..2000, 500, 0.25, nil, 3000, 125),
    VolumeType::IO2 => Limits.new(100..256_000, nil, 1000, nil, nil, 3000, nil),
    VolumeType::HYPERDISK_BALANCED => Limits.new(3000..160_000, 140..2400, 500, 0.25, 1.0 / 256, 3000, 140),
  }.freeze

  many_to_one :location
  one_to_one :aws_volume, key: :id, read_only: true
  one_to_one :gcp_volume, key: :id, read_only: true

  # The attachment, when one exists. A volume outlives the VM that mounts it,
  # so this is nil for a volume that is provisioned but not yet attached, or
  # detached and awaiting reuse.
  one_to_one :vm_storage_volume

  plugin ResourceMethods
  plugin ProviderDispatcher, __FILE__

  def provider_dispatcher_group_name
    location.provider_dispatcher_group_name
  end

  # Provider-specific configuration lives in the side table, so reach it
  # through the provider rather than duplicating readers here.
  def config = provider_config

  def volume_type = config.volume_type

  def limits = LIMITS.fetch(volume_type)

  def attached? = !vm_storage_volume.nil?
end

# Table: network_volume
# Columns:
#  id          | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(699)
#  created_at  | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  location_id | uuid                     | NOT NULL
#  provider_id | text                     |
#  size_gib    | bigint                   | NOT NULL
# Indexes:
#  network_volume_pkey | PRIMARY KEY btree (id)
# Check constraints:
#  network_volume_size_positive | (size_gib > 0)
# Foreign key constraints:
#  network_volume_location_id_fkey | (location_id) REFERENCES location(id)
# Referenced By:
#  aws_volume        | aws_volume_id_fkey                       | (id) REFERENCES network_volume(id)
#  gcp_volume        | gcp_volume_id_fkey                       | (id) REFERENCES network_volume(id)
#  vm_storage_volume | vm_storage_volume_network_volume_id_fkey | (network_volume_id) REFERENCES network_volume(id)
