# frozen_string_literal: true

RSpec.describe ArchilClient do
  let(:host) { "https://control.green.us-east-1.aws.prod.archil.com" }
  let(:client) { described_class.new("aws-us-east-1", api_key: "test-api-key") }

  def envelope(data)
    {success: true, data:}.to_json
  end

  describe ".control_plane_host" do
    it "maps each archil region to its control-plane cell" do
      expect(described_class.control_plane_host("aws-us-east-1")).to eq("https://control.green.us-east-1.aws.prod.archil.com")
      expect(described_class.control_plane_host("gcp-us-central1")).to eq("https://control.blue.us-central1.gcp.prod.archil.com")
    end

    it "refuses a region without a known cell" do
      expect { described_class.control_plane_host("aws-mars-1") }.to raise_error(RuntimeError, "Unknown Archil region: aws-mars-1")
    end
  end

  describe "#initialize" do
    it "defaults the api key to Config.archil_api_key and prefixes it" do
      expect(Config).to receive(:archil_api_key).and_return("config-api-key")
      stub = stub_request(:get, "#{host}/api/disks")
        .with(headers: {"Authorization" => "key-config-api-key", "User-Agent" => "ubicloud"})
        .to_return(status: 200, body: envelope([]))
      described_class.new("aws-us-east-1").list_disks
      expect(stub).to have_been_requested
    end

    it "keeps an already-prefixed api key intact" do
      stub = stub_request(:get, "#{host}/api/disks")
        .with(headers: {"Authorization" => "key-abc"})
        .to_return(status: 200, body: envelope([]))
      described_class.new("aws-us-east-1", api_key: "key-abc").list_disks
      expect(stub).to have_been_requested
    end

    it "fails fast when no api key is configured" do
      expect(Config).to receive(:archil_api_key).and_return(nil)
      expect { described_class.new("aws-us-east-1") }.to raise_error(RuntimeError, "No Archil API key is configured")
    end

    it "bounds connect and read waits so a hung control plane cannot wedge a strand" do
      connection = client.instance_variable_get(:@connection)
      expect(connection.data[:connect_timeout]).to eq 30
      expect(connection.data[:read_timeout]).to eq 30
    end
  end

  describe "envelope handling" do
    it "raises a typed error carrying the vendor message and code on success: false" do
      stub_request(:get, "#{host}/api/disks").to_return(status: 200, body: {success: false, error: "quota exceeded", code: "disk_limit_reached"}.to_json)
      expect { client.list_disks }.to raise_error(ArchilClient::Error, "quota exceeded") do |error|
        expect(error.code).to eq "disk_limit_reached"
      end
    end

    it "reports a placeholder when the failure envelope carries no message" do
      stub_request(:get, "#{host}/api/disks").to_return(status: 200, body: {success: false}.to_json)
      expect { client.list_disks }.to raise_error(ArchilClient::Error, "Archil API request failed (status 200)") do |error|
        expect(error.code).to be_nil
      end
    end

    it "raises a typed error rather than a parse error when a 2xx body is not JSON" do
      stub_request(:get, "#{host}/api/disks").to_return(status: 200, body: "<html>proxy error</html>")
      expect { client.list_disks }.to raise_error(ArchilClient::Error, "Archil API request failed (status 200)")
    end

    it "raises a typed error when a 2xx body is JSON but not the envelope hash" do
      stub_request(:get, "#{host}/api/disks").to_return(status: 200, body: [1, 2].to_json)
      expect { client.list_disks }.to raise_error(ArchilClient::Error, "Archil API request failed (status 200)")
    end
  end

  describe "#create_disk" do
    it "creates the disk and returns its id with the token user's credential and identifier" do
      stub_request(:post, "#{host}/api/disks")
        .with(body: {name: "my-disk"}.to_json)
        .to_return(status: 201, body: envelope({
          "diskId" => "disk-123",
          "authorizedUsers" => [{"type" => "iam"}, {"type" => "token", "token" => "secret-token", "identifier" => "user-1"}],
        }))
      expect(client.create_disk("my-disk")).to eq({disk_id: "disk-123", token: "secret-token", token_identifier: "user-1"})
    end

    it "fails when the created disk has no token user" do
      stub_request(:post, "#{host}/api/disks")
        .to_return(status: 201, body: envelope({"diskId" => "disk-123", "authorizedUsers" => [{"type" => "iam"}]}))
      expect { client.create_disk("my-disk") }.to raise_error(RuntimeError, "Archil disk disk-123 was created without a token user")
    end

    it "raises AlreadyExists on an idempotent 200 replay, whose one-time token cannot be re-read" do
      stub_request(:post, "#{host}/api/disks")
        .to_return(status: 200, body: envelope({"diskId" => "disk-123", "authorizedUsers" => [{"type" => "token", "identifier" => "user-1"}]}))
      expect { client.create_disk("my-disk") }.to raise_error(ArchilClient::AlreadyExists, "Archil disk my-disk already exists as disk-123")
    end

    it "raises AlreadyExists with the vendor message and code on a 409 name conflict" do
      stub_request(:post, "#{host}/api/disks")
        .to_return(status: 409, body: {success: false, error: "disk exists with different configuration", code: "disk_conflict"}.to_json)
      expect { client.create_disk("my-disk") }.to raise_error(ArchilClient::AlreadyExists, "disk exists with different configuration") do |error|
        expect(error.code).to eq "disk_conflict"
      end
    end

    it "raises AlreadyExists with a placeholder when the 409 body carries no message" do
      stub_request(:post, "#{host}/api/disks").to_return(status: 409, body: {success: false}.to_json)
      expect { client.create_disk("my-disk") }.to raise_error(ArchilClient::AlreadyExists, "Archil disk my-disk already exists")
    end

    it "raises AlreadyExists rather than a parse error when the 409 body is not JSON" do
      stub_request(:post, "#{host}/api/disks").to_return(status: 409, body: "<html>proxy error</html>")
      expect { client.create_disk("my-disk") }.to raise_error(ArchilClient::AlreadyExists, "Archil disk my-disk already exists")
    end
  end

  describe "#get_disk" do
    it "returns the disk data with the documented usage fields" do
      stub_request(:get, "#{host}/api/disks/disk-123")
        .to_return(status: 200, body: envelope({"id" => "disk-123", "activeDataBytes" => 1024, "totalDataBytes" => 4096}))
      expect(client.get_disk("disk-123")).to eq({"id" => "disk-123", "activeDataBytes" => 1024, "totalDataBytes" => 4096})
    end
  end

  describe "#list_disks" do
    it "returns all disks visible to the api key" do
      stub_request(:get, "#{host}/api/disks").to_return(status: 200, body: envelope([{"id" => "disk-123"}, {"id" => "disk-456"}]))
      expect(client.list_disks).to eq([{"id" => "disk-123"}, {"id" => "disk-456"}])
    end
  end

  describe "#delete_disk" do
    it "deletes the disk" do
      stub_request(:delete, "#{host}/api/disks/disk-123").to_return(status: 200, body: envelope({"message" => "deleted"}))
      expect(client.delete_disk("disk-123")).to be_nil
    end

    it "treats an already-deleted disk as success" do
      stub_request(:delete, "#{host}/api/disks/disk-123").to_return(status: 404, body: {success: false, error: "not found"}.to_json)
      expect(client.delete_disk("disk-123")).to be_nil
    end
  end

  describe "#create_disk_user" do
    it "mints a revocable mount credential and returns its token and identifier" do
      stub_request(:post, "#{host}/api/disks/disk-123/users")
        .with(body: {type: "token", nickname: "pvubid1"}.to_json)
        .to_return(status: 201, body: envelope({"type" => "token", "nickname" => "pvubid1", "token" => "vm-token", "identifier" => "user-2"}))
      expect(client.create_disk_user("disk-123", nickname: "pvubid1")).to eq({token: "vm-token", identifier: "user-2"})
    end
  end

  describe "#delete_disk_user" do
    it "revokes the credential by its identifier" do
      stub = stub_request(:delete, "#{host}/api/disks/disk-123/users/token")
        .with(query: {"identifier" => "user-2"})
        .to_return(status: 200, body: envelope({"message" => "removed"}))
      expect(client.delete_disk_user("disk-123", identifier: "user-2")).to be_nil
      expect(stub).to have_been_requested
    end

    it "treats an already-removed credential as success" do
      stub_request(:delete, "#{host}/api/disks/disk-123/users/token")
        .with(query: {"identifier" => "user-2"})
        .to_return(status: 404, body: {success: false, error: "not found"}.to_json)
      expect(client.delete_disk_user("disk-123", identifier: "user-2")).to be_nil
    end
  end

  describe "#list_branches" do
    it "returns the disk's branches" do
      stub_request(:get, "#{host}/api/disks/disk-123/branches").to_return(status: 200, body: envelope([{"branch_name" => "pbubid1"}]))
      expect(client.list_branches("disk-123")).to eq([{"branch_name" => "pbubid1"}])
    end
  end

  describe "#create_branch" do
    it "forks a checkpoint taken on the disk root into a branch" do
      stub_request(:post, "#{host}/api/disks/disk-123/branches")
        .with(body: {branch_name: "pbubid1", from_checkpoint_name: "pbubid1"}.to_json)
        .to_return(status: 201, body: envelope({"branch_name" => "pbubid1"}))
      expect(client.create_branch("disk-123", branch_name: "pbubid1", from_checkpoint_name: "pbubid1")).to eq({"branch_name" => "pbubid1"})
    end

    it "scopes the checkpoint lookup with from_branch when it was taken on a branch" do
      stub_request(:post, "#{host}/api/disks/disk-123/branches")
        .with(body: {branch_name: "pbubid2", from_checkpoint_name: "pbubid2", from_branch: "pbubid1"}.to_json)
        .to_return(status: 200, body: envelope({"branch_name" => "pbubid2"}))
      expect(client.create_branch("disk-123", branch_name: "pbubid2", from_checkpoint_name: "pbubid2", from_branch: "pbubid1")).to eq({"branch_name" => "pbubid2"})
    end
  end

  describe "#list_checkpoints" do
    it "returns the checkpoints taken on the disk root" do
      stub_request(:get, "#{host}/api/disks/disk-123/checkpoints")
        .to_return(status: 200, body: envelope([{"checkpoint_name" => "cp1"}]))
      expect(client.list_checkpoints("disk-123")).to eq([{"checkpoint_name" => "cp1"}])
    end

    it "scopes the listing to a branch's checkpoints when branch is given" do
      stub_request(:get, "#{host}/api/disks/disk-123/checkpoints")
        .with(query: {"branch" => "pbubid1"})
        .to_return(status: 200, body: envelope([{"checkpoint_name" => "cp2"}]))
      expect(client.list_checkpoints("disk-123", branch: "pbubid1")).to eq([{"checkpoint_name" => "cp2"}])
    end
  end
end
