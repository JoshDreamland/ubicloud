# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresArchilDisk do
  subject(:disk) { described_class.create(disk_id: "disk-123", token: "mount-token", region: "aws-us-east-1") }

  it "uses the pk ubid type" do
    expect(disk.ubid).to start_with("pk")
  end

  it "encrypts the token" do
    expect(disk.token).to eq("mount-token")
    expect(described_class.dataset.where(id: disk.id).get(:token)).not_to eq("mount-token")
  end

  it "allows an intent row without a vendor disk_id or token" do
    intent = described_class.create(region: "aws-us-east-1")
    expect(intent.disk_id).to be_nil
    expect(intent.token).to be_nil
  end

  it "lists the postgres disks carved from it" do
    project = Project.create(name: "postgres-archil-disk")
    resource = create_postgres_resource(project:, location_id: Location::HETZNER_FSN1_ID)
    postgres_branch_disk = PostgresBranchDisk.create(postgres_resource: resource, archil_disk: disk)
    expect(disk.postgres_branch_disks).to eq([postgres_branch_disk])
  end
end
