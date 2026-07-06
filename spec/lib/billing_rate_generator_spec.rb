# frozen_string_literal: true

require "yaml"

RSpec.describe BillingRateGenerator do
  def config(**overrides)
    {
      "vmResourceTypes" => ["VmVCpu", "VmStorage"],
      "postgresVCpuTypes" => ["PostgresVCpu", "PostgresStandbyVCpu"],
      "postgresStorageTypes" => ["PostgresStorage", "PostgresStandbyStorage"],
      "instanceResourceFamilies" => ["c6gd", "m6id"],
      "regions" => ["us-west-2", "us-east-1"],
      "activeFrom" => "2025-10-20T00:00:00Z",
    }.merge(overrides.transform_keys(&:to_s))
  end

  def gen(kind:, base_text: "", override_text: nil, **cfg)
    described_class.new(kind:, config: config(**cfg), base_text:, override_text:)
  end

  def records_of(text)
    YAML.load(text, permitted_classes: [Time]) || []
  end

  def generated_lines(text)
    text.lines.map(&:rstrip).select { it.start_with?("- {") }
  end

  describe "#matrix_records" do
    it "builds vm rows as resourceTypes x families x regions with family unchanged" do
      records = gen(kind: :vm).matrix_records
      expect(records.size).to eq(2 * 2 * 2)
      expect(records.first).to eq(
        "resource_type" => "VmVCpu", "resource_family" => "c6gd", "location" => "us-west-2",
        "unit_price" => 0.0, "billed_by" => "duration", "active_from" => "2025-10-20T00:00:00Z", "byoc" => false,
      )
      expect(records.map { it["resource_type"] }.uniq).to eq(["VmVCpu", "VmStorage"])
      expect(records.map { it["resource_family"] }.uniq).to eq(["c6gd", "m6id"])
    end

    it "builds postgres rows with storage (standard) first, then vcpu (standard-<family>)" do
      records = gen(kind: :postgres).matrix_records
      expect(records.size).to eq((2 * 2) + (2 * 2 * 2))
      storage = records.first(4)
      expect(storage.map { it["resource_type"] }.uniq).to eq(["PostgresStorage", "PostgresStandbyStorage"])
      expect(storage.map { it["resource_family"] }.uniq).to eq(["standard"])
      vcpu = records.last(8)
      expect(vcpu.map { it["resource_type"] }.uniq).to eq(["PostgresVCpu", "PostgresStandbyVCpu"])
      expect(vcpu.map { it["resource_family"] }.uniq).to eq(["standard-c6gd", "standard-m6id"])
    end

    it "normalizes a Time activeFrom into a canonical ...Z string" do
      records = gen(kind: :vm, activeFrom: Time.utc(2026, 1, 2, 3, 4, 5)).matrix_records
      expect(records.first["active_from"]).to eq("2026-01-02T03:04:05Z")
    end

    it "ignores excludedFamilies (a test-only key) so billing-rate output is unaffected" do
      with_key = gen(kind: :vm, excludedFamilies: ["c6gd", "m6id"]).matrix_records
      without_key = gen(kind: :vm).matrix_records
      expect(with_key).to eq(without_key)
    end
  end

  describe "#generate" do
    it "omits combos already present in the base file (existing rates take precedence)" do
      base = "- { id: 11111111-1111-1111-1111-111111111111, resource_type: VmVCpu, resource_family: c6gd, location: us-west-2, unit_price: 0.5, billed_by: duration, active_from: 2024-01-01T00:00:00Z, byoc: false }\n"
      out = gen(kind: :vm, base_text: base).generate
      keys = generated_lines(out.sub(base.rstrip, "")).map { records_of(it).first.values_at("resource_type", "resource_family", "location") }
      expect(keys).not_to include(["VmVCpu", "c6gd", "us-west-2"])
      expect(records_of(out).count { it.values_at("resource_type", "resource_family", "location") == ["VmVCpu", "c6gd", "us-west-2"] }).to eq(1)
      expect(out).to include("id: 11111111-1111-1111-1111-111111111111")
      expect(out).to include("unit_price: 0.5,")
    end

    it "preserves base bytes verbatim (including manual non-matrix records) even without a trailing newline" do
      base = "# header comment\n- { id: 22222222-2222-2222-2222-222222222222, resource_type: IPAddress, resource_family: IPv4, location: us-west-2, unit_price: 0.005, billed_by: duration, active_from: 2024-01-01T00:00:00Z, byoc: false }"
      out = gen(kind: :vm, base_text: base).generate
      expect(out).to start_with("#{base}\n")
      expect(out).to include("resource_type: IPAddress")
    end

    it "ignores a comment-only base and still appends the generated section" do
      out = gen(kind: :vm, base_text: "# comment only\n").generate
      expect(out).to start_with("# comment only\n")
      expect(records_of(out).size).to eq(8)
    end

    it "reuses the id from an existing override file for a generated combo" do
      override = "- { id: aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa, resource_type: VmVCpu, resource_family: m6id, location: us-east-1, unit_price: 0.0000000000, billed_by: duration, active_from: 2025-10-20T00:00:00Z, byoc: false }\n"
      out = gen(kind: :vm, override_text: override).generate
      line = generated_lines(out).find { records_of(it).first.values_at("resource_type", "resource_family", "location") == ["VmVCpu", "m6id", "us-east-1"] }
      expect(records_of(line).first["id"]).to eq("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    end

    it "mints a fresh uuid for a brand-new combo" do
      out = gen(kind: :vm).generate
      id = records_of(out).first["id"]
      expect(id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
    end

    it "appends brand-new combos only at the end, preserving existing override order" do
      override =
        "- { id: cccccccc-cccc-cccc-cccc-cccccccccccc, resource_type: VmVCpu, resource_family: c6gd, location: eu-west-1, unit_price: 0.0000000000, billed_by: duration, active_from: 2025-10-20T00:00:00Z, byoc: false }\n" \
        "- { id: bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb, resource_type: VmVCpu, resource_family: c6gd, location: us-east-1, unit_price: 0.0000000000, billed_by: duration, active_from: 2025-10-20T00:00:00Z, byoc: false }\n"
      out = gen(kind: :vm, override_text: override,
        vmResourceTypes: ["VmVCpu"], instanceResourceFamilies: ["c6gd"],
        regions: ["us-west-2", "us-east-1", "eu-west-1"]).generate
      order = generated_lines(out).map { records_of(it).first["location"] }
      expect(order).to eq(["eu-west-1", "us-east-1", "us-west-2"])
    end

    it "is idempotent: feeding its own output back produces identical bytes" do
      base = "- { id: 33333333-3333-3333-3333-333333333333, resource_type: VmVCpu, resource_family: c6gd, location: us-west-2, unit_price: 0.5, billed_by: duration, active_from: 2024-01-01T00:00:00Z, byoc: false }\n"
      first = gen(kind: :vm, base_text: base).generate
      second = gen(kind: :vm, base_text: base, override_text: first).generate
      expect(second).to eq(first)
    end

    it "treats an updated base as primary truth and the old override as secondary on regeneration" do
      cfg = {vmResourceTypes: ["VmVCpu"], instanceResourceFamilies: ["c6gd", "m6id"], regions: ["us-west-2"]}
      override_v1 = gen(kind: :vm, base_text: "", **cfg).generate
      reused_id = records_of(override_v1).find { it.values_at("resource_family", "location") == ["m6id", "us-west-2"] }["id"]

      # Base is updated to own the c6gd combo (its own id + real price); regenerate against the old override.
      base_v2 = "- { id: 0a0a0a0a-0a0a-0a0a-0a0a-0a0a0a0a0a0a, resource_type: VmVCpu, resource_family: c6gd, location: us-west-2, unit_price: 0.7, billed_by: duration, active_from: 2026-01-01T00:00:00Z, byoc: false }\n"
      out = gen(kind: :vm, base_text: base_v2, override_text: override_v1, **cfg).generate

      c6gd = records_of(out).select { it.values_at("resource_family", "location") == ["c6gd", "us-west-2"] }
      expect(c6gd.map { it["id"] }).to eq(["0a0a0a0a-0a0a-0a0a-0a0a-0a0a0a0a0a0a"]) # base primary: kept once, base id + price
      expect(c6gd.first["unit_price"]).to eq(0.7)

      m6id = records_of(out).find { it.values_at("resource_family", "location") == ["m6id", "us-west-2"] }
      expect(m6id["id"]).to eq(reused_id) # old override secondary: generated id preserved
      expect(m6id["unit_price"]).to eq(0.0)
    end

    it "formats generated lines to match the existing column layout" do
      out = gen(kind: :vm, vmResourceTypes: ["VmVCpu"], instanceResourceFamilies: ["c6gd"], regions: ["us-west-2"]).generate
      line = generated_lines(out).first
      expect(line.index("resource_type:")).to eq(46)
      expect(line.index("resource_family:")).to eq(90)
      expect(line.index("location:")).to eq(135)
      expect(line.index("unit_price:")).to eq(161)
      expect(line).to include("unit_price: 0.0000000000, billed_by: duration, active_from: 2025-10-20T00:00:00Z, byoc: false }")
      expect(records_of(line).first["unit_price"]).to eq(0.0)
    end

    it "emits only the generated section (with header) when the base is empty" do
      out = gen(kind: :vm, base_text: "").generate
      expect(out).to start_with("# ")
      expect(records_of(out).size).to eq(8)
    end

    it "treats a nil base the same as an empty base" do
      out = gen(kind: :vm, base_text: nil).generate
      expect(records_of(out).size).to eq(8)
    end

    it "returns the base unchanged (no header) when every combo already exists" do
      base = gen(kind: :vm).generate.sub(/^# .*\n/, "")
      out = gen(kind: :vm, base_text: base).generate
      expect(out).to eq(base)
      expect(out).not_to include("# ---")
    end
  end
end
