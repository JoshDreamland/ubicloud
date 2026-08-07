# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresWalShadow do
  let(:project) { Project.create(name: "test-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }
  let(:postgres_resource) { create_postgres_resource(project:, location_id:) }
  let(:ws) { Prog::Postgres::PostgresWalShadowNexus.assemble(postgres_resource.id, ch_config: "[ch]\n", boot_image: "ami").subject }

  describe "#display_state" do
    it "is creating while the strand is still starting" do
      expect(ws.display_state).to eq "creating"
    end

    it "is running once the strand reaches wait" do
      ws.strand.update(label: "wait")
      expect(ws.display_state).to eq "running"
    end

    it "is deleting when the destroy semaphore is set" do
      ws.incr_destroy
      expect(ws.display_state).to eq "deleting"
    end

    it "is deleting when there is no strand" do
      bare = described_class.create(project_id: project.id, postgres_resource_id: postgres_resource.id, base_ch_config: "x")
      expect(bare.display_state).to eq "deleting"
    end
  end

  describe "#instance_store_path" do
    it "keeps shadow-data and spill off instance store unless durability is waived" do
      expect(ws.instance_store_path).to eq "/var/lib/walshadow/out"
      ws.update(data_on_boot_volume: false)
      expect(ws.instance_store_path).to eq "/var/lib/walshadow"
    end
  end

  describe "#path and #display_location" do
    it "hangs off the postgres path" do
      expect(ws.path).to eq "#{postgres_resource.path}/wal-shadow"
      expect(ws.display_location).to eq postgres_resource.display_location
    end
  end

  describe "#api_config_hash" do
    it "defaults to an empty hash" do
      expect(ws.api_config_hash).to eq({})
    end

    it "parses the stored json" do
      ws.update(api_ch_config: JSON.generate({"ch" => {"url" => "u"}}))
      expect(ws.api_config_hash).to eq({"ch" => {"url" => "u"}})
    end
  end

  describe "#merge_api_config! and #unset_api_config!" do
    it "deep-merges and unsets" do
      ws.merge_api_config!({"ch" => {"url" => "u", "secure" => true}})
      ws.merge_api_config!({"ch" => {"url" => "v"}})
      expect(ws.api_config_hash).to eq({"ch" => {"url" => "v", "secure" => true}})
      ws.unset_api_config!(["ch.secure"])
      expect(ws.api_config_hash).to eq({"ch" => {"url" => "v"}})
    end
  end
end
