# frozen_string_literal: true

class Serializers::PostgresWalShadow < Serializers::Base
  def self.serialize_internal(ws, options = {})
    base = {
      id: ws.ubid,
      postgres_id: ws.postgres_resource.ubid,
      location: ws.display_location,
      state: ws.display_state,
      vm_size: ws.strand.stack.first["vm_size"],
      storage_size_gib: ws.strand.stack.first["storage_size_gib"],
      data_on_boot_volume: ws.data_on_boot_volume,
      created_at: ws.created_at.iso8601,
    }

    if options[:detailed]
      base[:status] = serialize_status(ws)
      base[:config] = ws.api_config_hash
    end

    base
  end

  def self.serialize_status(ws)
    status = ws.status || {}
    {
      paused: status["paused"],
      rows_synced: status["rows_synced"],
      backfills_pending: status["backfills_pending"],
      lag_bytes: status["lag_bytes"],
      lag_seconds: status["lag_seconds"],
      uptime_secs: status["uptime_secs"],
      refreshed_at: ws.status_at&.iso8601,
    }
  end
end
