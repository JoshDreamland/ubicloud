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
end
