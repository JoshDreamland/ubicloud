# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresBranchDisk do
  subject(:postgres_branch_disk) { described_class.create(postgres_resource: resource, archil_disk: disk) }

  let(:project) { Project.create(name: "postgres-disk") }
  let(:resource) { create_postgres_resource(project:, location_id: Location::HETZNER_FSN1_ID) }
  let(:disk) { PostgresArchilDisk.create(disk_id: "disk-123", token: "mount-token", region: "aws-us-east-1") }

  it "uses the dk ubid type" do
    expect(postgres_branch_disk.ubid).to start_with("dk")
  end

  it "joins its parent postgres resource to its archil disk" do
    expect(postgres_branch_disk.postgres_resource).to eq(resource)
    expect(postgres_branch_disk.archil_disk).to eq(disk)
    expect(resource.postgres_branch_disks).to eq([postgres_branch_disk])
    expect(disk.postgres_branch_disks).to eq([postgres_branch_disk])
  end

  it "starts creating, detached, and user-owned, with the cut not yet recorded" do
    expect(postgres_branch_disk.state).to eq("creating")
    expect(postgres_branch_disk.attached_to).to be_nil
    expect(postgres_branch_disk.owned).to be false
    expect(postgres_branch_disk.target_time).to be_nil
    expect(postgres_branch_disk.source_time).to be_nil
    expect(postgres_branch_disk.wal_source_branch).to be_nil
    expect(postgres_branch_disk.token_identifier).to be_nil
  end

  it "has a helper for each lifecycle state" do
    helpers = {"creating" => :creating?, "ready" => :ready?, "attached" => :attached?, "deleting" => :deleting?, "failed" => :failed?}
    helpers.each_key do |state|
      postgres_branch_disk.update(state:)
      helpers.each { |name, helper| expect(postgres_branch_disk.send(helper)).to eq(name == state) }
    end
  end

  it "rejects states outside the lifecycle" do
    expect { postgres_branch_disk.update(state: "poked") }.to raise_error(Sequel::ValidationFailed, "state is invalid")
  end

  it "tracks the branch mounting it, at most one disk per branch" do
    branch = create_postgres_resource(project:, location_id: Location::HETZNER_FSN1_ID)
    postgres_branch_disk.update(attached_to: branch, state: "attached")
    expect(postgres_branch_disk.attached_to).to eq(branch)
    expect(branch.postgres_branch_disk_attached).to eq(postgres_branch_disk)

    other = described_class.create(postgres_resource: resource, archil_disk: disk)
    expect { other.update(attached_to: branch) }.to raise_error(Sequel::ValidationFailed, "attached_to_id is already taken")
  end

  it "detaches when the branch resource row is deleted out from under it" do
    branch = create_postgres_resource(project:, location_id: Location::HETZNER_FSN1_ID)
    postgres_branch_disk.update(attached_to: branch, state: "attached")
    branch.destroy
    expect(postgres_branch_disk.refresh.attached_to_id).to be_nil
  end

  it "is destroyed with its parent postgres resource, leaving the vendor disk row behind" do
    postgres_branch_disk
    expect { resource.destroy }.to change { described_class.count }.from(1).to(0)
    expect(disk.exists?).to be true
  end
end
