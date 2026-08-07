# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe ChConfig do
  describe ".deep_merge" do
    it "recurses into nested hashes and overrides scalars" do
      expect(described_class.deep_merge({"a" => {"b" => 1}}, {"a" => {"c" => 2}, "d" => 3})).to eq({"a" => {"b" => 1, "c" => 2}, "d" => 3})
      expect(described_class.deep_merge({"a" => 1}, {"a" => 2})).to eq({"a" => 2})
    end
  end

  describe ".delete_paths" do
    it "removes leaves and prunes emptied subtrees" do
      hash = {"ch" => {"url" => "u"}, "stream" => {"paused" => true}}
      expect(described_class.delete_paths(hash, ["stream.paused"])).to eq({"ch" => {"url" => "u"}})
    end

    it "ignores paths that traverse a scalar" do
      expect(described_class.delete_paths({"a" => 1}, ["a.b"])).to eq({"a" => 1})
    end

    it "ignores paths whose parent is missing" do
      expect(described_class.delete_paths({}, ["a.b.c"])).to eq({})
    end
  end

  describe ".render_toml" do
    it "renders an empty config as an empty string" do
      expect(described_class.render_toml({})).to eq ""
    end

    it "renders top-level scalars into the root table" do
      expect(described_class.render_toml({"x" => 1})).to eq "x = 1\n"
    end

    it "renders nested tables and quotes keys that are not bare-key safe" do
      toml = described_class.render_toml({"table" => {"my schema" => {"t" => {"replicate" => true}}}})
      expect(toml).to eq "[table.\"my schema\".t]\nreplicate = true\n"
    end
  end

  describe ".parse_status_toml" do
    it "parses a flat status table into typed scalars" do
      toml = <<~TOML
        paused = true
        rows_synced = 42

        lag_seconds = 1.5
        note = "ok"
      TOML
      expect(described_class.parse_status_toml(toml)).to eq({
        "paused" => true,
        "rows_synced" => 42,
        "lag_seconds" => 1.5,
        "note" => "ok",
      })
    end
  end
end
