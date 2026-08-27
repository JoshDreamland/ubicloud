# frozen_string_literal: true

require_relative "../../../model/spec_helper"

RSpec.describe PostgresResource::PrependMethods do # rubocop:disable RSpec/SpecFilePathFormat
  let(:project) { Project.create(name: "postgres-resource") }
  let(:location_id) { Location::HETZNER_FSN1_ID }
  let(:resource) { create_postgres_resource(project:, location_id:) }

  describe "#read_replica_type" do
    it "is none for a non-replica resource" do
      expect(resource.read_replica_type).to eq(PostgresResource::ReadReplicaType::NONE)
    end

    it "is regional for a read replica" do
      parent = create_postgres_resource(project:, location_id:)
      resource.update(parent_id: parent.id)
      expect(resource.read_replica_type).to eq(PostgresResource::ReadReplicaType::REGIONAL)
    end
  end

  describe "#display_state" do
    before { project.set_ff_chc_postgres_deactivate_lockout(true) }

    it "returns 'deactivated' when the chc_state tag is set" do
      resource.update(tags: Sequel.pg_jsonb([{"key" => "chc_state", "value" => "deactivated"}]))
      expect(resource.display_state).to eq("deactivated")
    end

    it "returns 'deleting' (super) when destroy is set, even if chc_state=deactivated tag is present" do
      resource.update(tags: Sequel.pg_jsonb([{"key" => "chc_state", "value" => "deactivated"}]))
      resource.incr_destroy
      expect(resource.display_state).to eq("deleting")
    end

    it "returns 'deleting' (super) when destroying is set (destroy strand mid-flight)" do
      resource.update(tags: Sequel.pg_jsonb([{"key" => "chc_state", "value" => "deactivated"}]))
      resource.incr_destroying
      expect(resource.display_state).to eq("deleting")
    end

    it "delegates to super when no chc_state tag is set" do
      allow(resource).to receive(:representative_server).and_return(
        instance_double(PostgresServer, strand: instance_double(Strand, label: "wait"), restart_set?: false),
      )
      expect(resource.display_state).not_to eq("deactivated")
    end

    it "ignores customer tags whose key is 'chc_state' but value differs from 'deactivated'" do
      resource.update(tags: Sequel.pg_jsonb([{"key" => "chc_state", "value" => "something_else"}]))
      allow(resource).to receive(:representative_server).and_return(
        instance_double(PostgresServer, strand: instance_double(Strand, label: "wait"), restart_set?: false),
      )
      expect(resource.display_state).not_to eq("deactivated")
    end

    it "delegates to super when the chc_postgres_deactivate_lockout feature flag is OFF for the project" do
      project.set_ff_chc_postgres_deactivate_lockout(false)
      resource.update(tags: Sequel.pg_jsonb([{"key" => "chc_state", "value" => "deactivated"}]))
      allow(resource).to receive(:representative_server).and_return(
        instance_double(PostgresServer, strand: instance_double(Strand, label: "wait"), restart_set?: false),
      )
      expect(resource.display_state).not_to eq("deactivated")
    end
  end

  describe "#deactivate_requested?" do
    it "returns true when chc_state=deactivated tag is present" do
      resource.update(tags: Sequel.pg_jsonb([{"key" => "chc_state", "value" => "deactivated"}]))
      expect(resource.deactivate_requested?).to be(true)
    end

    it "returns false when no chc_state tag is present" do
      expect(resource.deactivate_requested?).to be(false)
    end

    it "returns false when chc_state tag has a different value" do
      resource.update(tags: Sequel.pg_jsonb([{"key" => "chc_state", "value" => "other"}]))
      expect(resource.deactivate_requested?).to be(false)
    end
  end

  describe "#deactivated?" do
    it "returns true when both chc_state and chc_deactivated_at tags are set" do
      resource.update(tags: Sequel.pg_jsonb([
        {"key" => "chc_state", "value" => "deactivated"},
        {"key" => "chc_deactivated_at", "value" => "2026-01-01T00:00:00Z"},
      ]))
      expect(resource.deactivated?).to be(true)
    end

    it "returns false when only chc_state is present (legacy hotfix row)" do
      resource.update(tags: Sequel.pg_jsonb([{"key" => "chc_state", "value" => "deactivated"}]))
      expect(resource.deactivated?).to be(false)
    end

    it "returns false when neither tag is present" do
      expect(resource.deactivated?).to be(false)
    end
  end
end
