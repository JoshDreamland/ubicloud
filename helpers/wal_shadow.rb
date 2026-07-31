# frozen_string_literal: true

class Clover
  def validate_wal_shadow_config!(config)
    # [source] is derived from the parent postgres; not editable via the API
    if config.key?("source")
      fail CloverError.new(400, "InvalidRequest", "walshadow [source] is derived from the database and cannot be edited via the API")
    end
    validate_wal_shadow_scalars!(config)
  end

  def validate_wal_shadow_scalars!(hash)
    hash.each_value do |value|
      case value
      when Hash
        validate_wal_shadow_scalars!(value)
      when String, Integer, Float, true, false
        next
      else
        fail CloverError.new(400, "InvalidRequest", "walshadow config values must be strings, numbers, or booleans")
      end
    end
  end

  # deep-merge into the API config, persist, and signal the strand to reconcile
  def apply_wal_shadow_config(ws, config)
    validate_wal_shadow_config!(config)
    DB.transaction do
      ws.merge_api_config!(config)
      ws.incr_update_config
      audit_log(ws, "update_config", @pg)
    end
  end
end
