# frozen_string_literal: true

require "toml-rb"

module ChConfig
  module_function

  def deep_merge(base, overlay)
    base.merge(overlay) do |_, old_val, new_val|
      (old_val.is_a?(Hash) && new_val.is_a?(Hash)) ? deep_merge(old_val, new_val) : new_val
    end
  end

  # Remove dotted key paths (e.g. "stream.paused"); prunes emptied parents
  def delete_paths(hash, paths)
    paths.each do |path|
      keys = path.split(".")
      leaf = keys[..-2].reduce(hash) { |node, key| node.is_a?(Hash) ? node[key] : nil }
      leaf.delete(keys.last) if leaf.is_a?(Hash)
    end
    prune_empty(hash)
  end

  def prune_empty(hash)
    hash.each_value { prune_empty(it) if it.is_a?(Hash) }
    hash.reject! { |_, v| v.is_a?(Hash) && v.empty? }
    hash
  end

  def render_toml(hash)
    TomlRB.dump(hash)
  end

  def parse_status_toml(text)
    TomlRB.parse(text)
  end

  ParseError = TomlRB::ParseError

  def parse(text)
    TomlRB.parse(text)
  end
end
