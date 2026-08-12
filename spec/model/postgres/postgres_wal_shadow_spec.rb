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

  describe "#timeline" do
    it "is nil without a representative server" do
      expect(ws.timeline).to be_nil
    end

    it "follows the representative server" do
      server = create_postgres_server(resource: postgres_resource)
      expect(ws.timeline).to eq server.timeline
    end
  end

  describe "on a non-aws location" do
    before do
      create_postgres_server(resource: postgres_resource)
      ws.update(vm_id: Prog::Vm::Nexus.assemble_with_sshable(project.id, location_id:).id)
    end

    it "attaches no policy" do
      expect(Config).to receive(:aws_postgres_iam_access).and_return(true)
      expect(ws.vm).not_to receive(:aws_instance)
      ws.attach_s3_policy_if_needed
    end

    it "names no bucket" do
      expect(ws.backup_config_hash).to eq({})
      expect(ws.backup_config_toml).to eq ""
    end
  end

  describe "timeline bucket access" do
    let(:location) {
      Location.create(name: "us-west-2", provider: "aws", project_id: project.id,
        display_name: "aws-us-west-2", ui_name: "AWS US West 2", visible: true)
    }
    let(:location_id) { location.id }
    let(:vm) { Prog::Vm::Nexus.assemble_with_sshable(project.id, location_id:).subject }
    let(:iam_client) { Aws::IAM::Client.new(stub_responses: true) }

    before do
      LocationCredentialAws.create(location:, assume_role: "role")
      LocationAz.create(location_id: location.id, zone_id: "usw2-az1", az: "a")
      create_postgres_server(resource: postgres_resource)
      ws.update(vm_id: vm.id)
    end

    describe "#attach_s3_policy_if_needed" do
      it "attaches the timeline policy to the vm role" do
        expect(Config).to receive(:aws_postgres_iam_access).and_return(true)
        AwsInstance.create_with_id(vm, iam_role: "role")
        credential = ws.timeline.location.location_credential_aws
        expect(credential).to receive(:aws_iam_account_id).and_return("aws-account-id").at_least(:once)
        expect(credential).to receive(:iam_client).and_return(iam_client)
        expect(iam_client).to receive(:attach_role_policy).with(role_name: "role", policy_arn: ws.timeline.aws_s3_policy_arn)
        ws.attach_s3_policy_if_needed
      end

      it "does nothing in access-key mode" do
        AwsInstance.create_with_id(vm, iam_role: "role")
        expect(ws).not_to receive(:timeline)
        ws.attach_s3_policy_if_needed
      end

      it "does nothing when the resource has no representative server" do
        expect(Config).to receive(:aws_postgres_iam_access).and_return(true)
        PostgresServer.where(resource_id: postgres_resource.id).all.each { it.update(is_representative: false) }
        expect(ws.vm).not_to receive(:aws_instance)
        ws.attach_s3_policy_if_needed
      end

      it "does nothing before the vm has an aws instance" do
        expect(Config).to receive(:aws_postgres_iam_access).and_return(true)
        expect(ws.timeline.location).not_to receive(:location_credential_aws)
        ws.attach_s3_policy_if_needed
      end
    end

    describe "#backup_config_hash and #backup_config_toml" do
      it "names the timeline bucket without credentials" do
        expect(ws.backup_config_hash).to eq({"backup" => {
          "archive" => "s3://#{ws.timeline.ubid}",
          "region" => location.name,
          "endpoint" => "https://s3.#{location.name}.amazonaws.com",
          "force_path_style" => true,
        }})
        expect(ws.backup_config_toml).to include("archive = \"s3://#{ws.timeline.ubid}\"")
        expect(ws.backup_config_toml).not_to include("access_key")
      end
    end
  end
end
