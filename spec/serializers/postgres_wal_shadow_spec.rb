# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Serializers::PostgresWalShadow do
  let(:project) { Project.create(name: "test-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }
  let(:postgres_resource) { create_postgres_resource(project:, location_id:) }
  let(:ws) { Prog::Postgres::PostgresWalShadowNexus.assemble(postgres_resource.id, ch_config: "[ch]\n", boot_image: "ami").subject }

  it "serializes the base view" do
    data = described_class.serialize(ws)
    expect(data).to eq({
      id: ws.ubid,
      postgres_id: postgres_resource.ubid,
      location: postgres_resource.display_location,
      state: "creating",
      vm_size: "standard-2",
      storage_size_gib: 40,
      data_on_boot_volume: true,
      created_at: ws.created_at.iso8601,
    })
  end

  it "serializes the detailed view with config and cached status" do
    ws.update(
      api_ch_config: JSON.generate({"ch" => {"url" => "u", "password" => "s"}}),
      status: {"paused" => true, "rows_synced" => 7},
      status_at: Time.now,
    )
    data = described_class.serialize(ws, {detailed: true})
    expect(data[:config]).to eq({"ch" => {"url" => "u", "password" => "s"}})
    expect(data[:status][:paused]).to be true
    expect(data[:status][:rows_synced]).to eq 7
    expect(data[:status][:refreshed_at]).not_to be_nil
  end

  it "serializes null status fields before the first refresh" do
    expect(described_class.serialize_status(ws)).to eq({
      paused: nil,
      rows_synced: nil,
      backfills_pending: nil,
      lag_bytes: nil,
      lag_seconds: nil,
      uptime_secs: nil,
      refreshed_at: nil,
    })
  end
end
