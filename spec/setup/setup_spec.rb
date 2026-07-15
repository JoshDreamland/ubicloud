# frozen_string_literal: true

require_relative "../../setup"

RSpec.describe "UbicloudSetup" do
  describe "should be always true" do
    it "hides locations that don't match clickgres pattern" do
      # Create test locations
      Location.create(
        name: "test-location",
        ui_name: "Test Location",
        display_name: "Test Location",
        provider: "aws",
        visible: true,
        project_id: nil,
      )

      Location.create(
        name: "clickgres-location",
        display_name: "Clickgres Location",
        ui_name: "Clickgres Location-clickgres",
        provider: "aws",
        visible: true,
        project_id: nil,
      )

      expect(Location.where(name: "test-location").first.visible).to be true
      # Run the method
      UbicloudSetup.hide_default_locations

      # Check that non-clickgres location is hidden
      expect(Location.where(name: "test-location").first.visible).to be false

      # Check that clickgres location is still visible
      expect(Location.where(name: "clickgres-location").first.visible).to be true
    end
  end

  describe "setup ubicloud" do
    it "create everything" do
      expect(Account.count).to eq 0
      expect(Project.count).to eq 0
      expect(ApiKey.count).to eq 0
      project_id = UBID.generate UBID::TYPE_PROJECT
      expect(project_id.to_s[0..1]).to eq "pj"
      UbicloudSetup.setup_ubicloud("email@domain.com", "password", "project-name", project_id.to_uuid)
      expect(Account.count).to eq 1
      expect(Project.count).to eq 1
      expect(ApiKey.count).to eq 1
    end

    it "use existing account" do
      Account.create(email: "email@domain.com", status_id: 2)
      expect(Account.count).to eq 1
      expect(Project.count).to eq 0
      expect(ApiKey.count).to eq 0
      project_id = UBID.generate UBID::TYPE_PROJECT
      expect(project_id.to_s[0..1]).to eq "pj"
      UbicloudSetup.setup_ubicloud("email@domain.com", "password", "project-name", project_id.to_uuid)
      expect(Account.count).to eq 1
      expect(Project.count).to eq 1
      expect(ApiKey.count).to eq 1
    end

    it "use existing project" do
      account = Account.create(email: "email@domain.com", status_id: 2)
      project = account.create_project_with_default_policy("project-name")
      expect(Account.count).to eq 1
      expect(Project.count).to eq 1
      UbicloudSetup.setup_ubicloud("email@domain.com", "password", "project-name", UBID.from_uuidish(project.id).to_uuid)
      expect(Account.count).to eq 1
      expect(Project.count).to eq 1
    end

    it "use existing api key" do
      account = Account.create(email: "email@domain.com", status_id: 2)
      project = account.create_project_with_default_policy("project-name")
      ApiKey.create_personal_access_token(account, project:)
      expect(Account.count).to eq 1
      expect(Project.count).to eq 1
      expect(ApiKey.count).to eq 1
      UbicloudSetup.setup_ubicloud("email@domain.com", "password", "project-name", UBID.from_uuidish(project.id).to_uuid)
      expect(Account.count).to eq 1
      expect(Project.count).to eq 1
      expect(ApiKey.count).to eq 1
    end
  end

  describe "setup_bot_account" do
    let(:account) { Account.create(email: "admin@domain.com", status_id: 2) }
    let(:project) { account.create_project_with_default_policy("project-name") }

    it "creates bot account and PAT with read-only access" do
      project
      expect(Account.count).to eq 1
      expect(ApiKey.count).to eq 0
      result = UbicloudSetup.setup_bot_account("bot@domain.com", "bot-password", project.id)
      expect(Account.count).to eq 2
      expect(ApiKey.count).to eq 1
      expect(result[:project_id]).to eq project.id
      expect(result[:token]).to eq "[REDACTED]"
      bot_account = Account.where(email: "bot@domain.com").first
      expect(bot_account).not_to be_nil

      # Bot account should be added to the project
      expect(bot_account.projects_dataset.where(id: project.id).count).to eq 1

      # Bot account's default project should be set
      bot_account.reload
      expect(bot_account.default_project).to eq project

      api_key = ApiKey.where(owner_id: bot_account.id, project_id: project.id).first
      expect(api_key).not_to be_nil
      expect(api_key.unrestricted_token_for_project?(project.id)).to be false

      # ACEs should be created for the API key (PAT)
      api_key_aces = AccessControlEntry.where(project_id: project.id, subject_id: api_key.id).all
      api_key_ace_actions = api_key_aces.map { |ace| ActionType[ace.action_id]&.name }
      expect(api_key_ace_actions).to contain_exactly("Postgres:view", "Project:view")

      # ACEs should also be created for the bot account itself
      account_aces = AccessControlEntry.where(project_id: project.id, subject_id: bot_account.id).all
      account_ace_actions = account_aces.map { |ace| ActionType[ace.action_id]&.name }
      expect(account_ace_actions).to contain_exactly("Postgres:view", "Project:view")
    end

    it "adds bot account to project and sets default project" do
      project
      UbicloudSetup.setup_bot_account("bot@domain.com", "bot-password", project.id)
      bot_account = Account.where(email: "bot@domain.com").first
      expect(bot_account.projects_dataset.where(id: project.id).count).to eq 1
      bot_account.reload
      expect(bot_account.default_project).to eq project
    end

    it "does not add bot account to project if already a member" do
      project
      bot_account = Account.create(email: "bot@domain.com", status_id: 2)
      bot_account.add_project project
      member_count_before = bot_account.projects_dataset.where(id: project.id).count
      expect(member_count_before).to eq 1
      UbicloudSetup.setup_bot_account("bot@domain.com", "bot-password", project.id)
      # Account should still only be associated once (no duplicate)
      expect(bot_account.projects_dataset.where(id: project.id).count).to eq 1
    end

    it "reuses existing bot account" do
      project
      Account.create(email: "bot@domain.com", status_id: 2)
      expect(Account.count).to eq 2
      UbicloudSetup.setup_bot_account("bot@domain.com", "bot-password", project.id)
      expect(Account.count).to eq 2
      expect(ApiKey.count).to eq 1
    end

    it "reuses existing bot PAT and is idempotent" do
      project
      bot_account = Account.create(email: "bot@domain.com", status_id: 2)
      ApiKey.create_personal_access_token(bot_account, project:)
      expect(ApiKey.count).to eq 1
      UbicloudSetup.setup_bot_account("bot@domain.com", "bot-password", project.id)
      expect(ApiKey.count).to eq 1
      api_key = ApiKey.where(owner_id: bot_account.id, project_id: project.id).first
      # 2 ACEs for API key, 2 ACEs for bot account (one per READ_ONLY_ACTIONS each)
      expect(AccessControlEntry.where(project_id: project.id, subject_id: api_key.id).count).to eq 2
      expect(AccessControlEntry.where(project_id: project.id, subject_id: bot_account.id).count).to eq 2
      # Running again should not create duplicate ACEs
      UbicloudSetup.setup_bot_account("bot@domain.com", "bot-password", project.id)
      expect(AccessControlEntry.where(project_id: project.id, subject_id: api_key.id).count).to eq 2
      expect(AccessControlEntry.where(project_id: project.id, subject_id: bot_account.id).count).to eq 2
    end

    it "fails if project does not exist" do
      expect {
        UbicloudSetup.setup_bot_account("bot@domain.com", "bot-password", SecureRandom.uuid)
      }.to raise_error(/not found for bot account/)
    end
  end

  describe "setup_oidc_provider" do
    let(:target_uuid) { SecureRandom.uuid }
    let(:oidc_config) {
      UbicloudSetup::OidcProviderConfig.new(
        display_name: "Test OIDC Provider",
        url: "https://accounts.google.com",
        client_id: "test-client-id",
        client_secret: "test-client-secret",
      )
    }

    before do
      stub_oidc_discovery("https://accounts.google.com")
      stub_oidc_discovery("https://updated.example.com")
    end

    it "creates OIDC provider with deterministic target UUID" do
      expect(OidcProvider.count).to eq 0
      UbicloudSetup.setup_oidc_provider(target_uuid, oidc_config)
      expect(OidcProvider.count).to eq 1
      provider = OidcProvider[target_uuid]
      expect(provider).not_to be_nil
      expect(provider.display_name).to eq "Test OIDC Provider"
    end

    it "replaces existing provider with same UUID (idempotent)" do
      UbicloudSetup.setup_oidc_provider(target_uuid, oidc_config)
      expect(OidcProvider.count).to eq 1
      updated_config = UbicloudSetup::OidcProviderConfig.new(
        display_name: "Updated OIDC Provider",
        url: "https://updated.example.com",
        client_id: "updated-client-id",
        client_secret: "updated-client-secret",
      )
      UbicloudSetup.setup_oidc_provider(target_uuid, updated_config)
      expect(OidcProvider.count).to eq 1
      expect(OidcProvider[target_uuid].display_name).to eq "Updated OIDC Provider"
    end
  end

  describe "with project" do
    let(:project_id) { UBID.generate UBID::TYPE_PROJECT }
    let(:project) do
      p = Project.new(name: "project-name")
      p.id = project_id.to_uuid
      p.save_changes
    end

    before do
      PgAwsAmi.create(aws_location_name: "some-region", pg_version: "18", arch: "x64", aws_ami_id: "ami-12345678")
    end

    it "has existing pg amis" do
      expect(PgAwsAmi.count).to be > 0
      expect(PgAwsAmi.where(aws_location_name: "some-region", pg_version: "18", arch: "x64").first).to have_attributes(aws_ami_id: "ami-12345678")
      UbicloudSetup.update_pg_amis("some-region", "pg18", {arch_x64: "ami-88888888", arch_arm64: "ami-99999999"})
      expect(PgAwsAmi.where(aws_location_name: "some-region", pg_version: "18", arch: "x64").first).to have_attributes(aws_ami_id: "ami-88888888")
    end

    it "upserts a pg_gce_image row, updating pg_versions in place on re-run" do
      PgGceImage.dataset.destroy
      name = "postgres-ubuntu-2404-x64-20260218"
      UbicloudSetup.update_pg_gce_image(UbicloudSetup::PgGceImageConfig.new(gce_image_name: name, arch: "x64", pg_versions: ["16", "17"]))
      img = PgGceImage.where(arch: "x64", gce_image_name: name)
      expect(img.count).to eq 1
      expect(img.first.pg_versions).to eq(["16", "17"])

      # same (arch, gce_image_name) key -> update in place, no duplicate row
      UbicloudSetup.update_pg_gce_image(UbicloudSetup::PgGceImageConfig.new(gce_image_name: name, arch: "x64", pg_versions: ["16", "17", "18"]))
      expect(img.count).to eq 1
      expect(img.first.pg_versions).to eq(["16", "17", "18"])
    end

    it "add_location" do
      old_count = Location.count

      UbicloudSetup.add_location(UbicloudSetup::LocationConfig.new(account_name: "account_name", name: "test-location", region: "region", role: "role", dns_suffix: "dns_suffix"))
      expect(Location.count).to eq(old_count + 1)
      expect(LocationCredentialAws.count).to eq 1
      # match the location 1:1
      location = Location.where(display_name: "test-location").first
      expect(location).to have_attributes(
        name: "region",
        ui_name: "account_name",
        display_name: "test-location",
        provider: "aws",
        visible: true,
        project_id: nil,
      )
      expect(LocationCredentialAws.last).to have_attributes(
        id: location.id,
        access_key: nil,
        secret_key: nil,
        assume_role: "role",
      )
    end

    it "update existing location and add new location credentials for existing location" do
      Location.create(
        name: "region",
        ui_name: "account_name",
        display_name: "test-location",
        provider: "aws",
        visible: true,
        project_id: nil,
      )
      old_count = Location.count
      expect(LocationCredentialAws.count).to eq 0
      UbicloudSetup.add_location(UbicloudSetup::LocationConfig.new(account_name: "account_name", name: "test-location", region: "region", role: "role", dns_suffix: "dns_suffix"))
      expect(Location.count).to eq(old_count)
      expect(LocationCredentialAws.count).to eq 1
      # match the location 1:1
      location = Location.where(display_name: "test-location").first
      expect(location).to have_attributes(
        name: "region",
        ui_name: "account_name",
        display_name: "test-location",
        provider: "aws",
        visible: true,
        project_id: nil,
        dns_suffix: "dns_suffix",
      )
      expect(LocationCredentialAws.last).to have_attributes(
        id: location.id,
        access_key: nil,
        secret_key: nil,
        assume_role: "role",
      )
    end

    it "update existing existing location and credentials" do
      location = Location.create(
        name: "region",
        ui_name: "account_name",
        display_name: "test-location",
        provider: "aws",
        visible: true,
        project_id: nil,
      )
      LocationCredentialAws.create_with_id(
        location.id,
        access_key: nil,
        secret_key: nil,
        assume_role: "role",
      )
      old_count = Location.count
      expect(LocationCredentialAws.count).to eq 1
      UbicloudSetup.add_location(UbicloudSetup::LocationConfig.new(account_name: "account_name", name: "test-location", region: "region", role: "role2", dns_suffix: "dns_suffix"))
      expect(Location.count).to eq(old_count)
      expect(LocationCredentialAws.count).to eq 1
      # match the location 1:1
      location = Location.where(display_name: "test-location").first
      expect(location).to have_attributes(
        name: "region",
        ui_name: "account_name",
        display_name: "test-location",
        provider: "aws",
        visible: true,
        project_id: nil,
        dns_suffix: "dns_suffix",
      )
      expect(LocationCredentialAws.last).to have_attributes(
        id: location.id,
        access_key: nil,
        secret_key: nil,
        assume_role: "role2",
      )
    end

    it "updates an existing otel_otlp_destination in place" do
      location = Location.create(name: "region", ui_name: "account_name", display_name: "test-location", provider: "aws", visible: true, project_id: nil)
      OtelOtlpDestination.create(
        otlp_data_endpoint: "https://old.example.com:4317",
        otlp_arrow_endpoint: "https://old-arrow.example.com:4317",
        logs_endpoint: "https://old-logs.example.com:4317",
        metrics_endpoint: "https://old-metrics.example.com:4317",
        auth_audience: "https://old.example.com",
      ) { it.id = location.id }

      updated = UbicloudSetup::OtelOtlpDestinationConfig.new(
        otlp_data_endpoint: "https://new.example.com:4317",
        otlp_arrow_endpoint: "https://new-arrow.example.com:4317",
        logs_endpoint: "https://new-logs.example.com:4317",
        metrics_endpoint: "https://new-metrics.example.com:4317",
        auth_audience: "https://new.example.com",
      )
      UbicloudSetup.add_location(UbicloudSetup::LocationConfig.new(account_name: "account_name", name: "test-location", region: "region", role: "role", dns_suffix: "dns_suffix", otel_otlp_destination: updated))

      expect(OtelOtlpDestination.count).to eq 1
      expect(OtelOtlpDestination[location.id]).to have_attributes(
        otlp_data_endpoint: "https://new.example.com:4317",
        otlp_arrow_endpoint: "https://new-arrow.example.com:4317",
        logs_endpoint: "https://new-logs.example.com:4317",
        metrics_endpoint: "https://new-metrics.example.com:4317",
        auth_audience: "https://new.example.com",
      )
    end

    it "normalizes an empty dns_suffix to nil" do
      UbicloudSetup.add_location(UbicloudSetup::LocationConfig.new(account_name: "account_name", name: "test-location", region: "region", role: "role", dns_suffix: ""))
      expect(Location.where(display_name: "test-location").first.dns_suffix).to be_nil
    end

    it "add_location for gcp provider creates a gcp location and gcp credential" do
      UbicloudSetup.add_location(UbicloudSetup::LocationConfig.new(
        account_name: "gcp-account", name: "GCP US Central 1", region: "gcp-us-central1",
        provider: "gcp", gcp_project_id: "my-gcp-project",
        service_account_email: "clickgres@my-gcp-project.iam.gserviceaccount.com",
      ))
      location = Location.where(display_name: "GCP US Central 1").first
      expect(location).to have_attributes(
        name: "gcp-us-central1",
        ui_name: "gcp-account",
        provider: "gcp",
        visible: true,
        project_id: nil,
      )
      expect(LocationCredentialAws.count).to eq 0
      expect(LocationCredentialGcp.count).to eq 1
      expect(LocationCredentialGcp[location.id]).to have_attributes(
        project_id: "my-gcp-project",
        service_account_email: "clickgres@my-gcp-project.iam.gserviceaccount.com",
        credentials_json: nil,
      )
    end

    it "add_location for gcp provider adds a credential to an existing gcp location" do
      Location.create(name: "gcp-us-central1", ui_name: "gcp-account", display_name: "GCP US Central 1", provider: "gcp", visible: true, project_id: nil)
      expect(LocationCredentialGcp.count).to eq 0
      UbicloudSetup.add_location(UbicloudSetup::LocationConfig.new(
        account_name: "gcp-account", name: "GCP US Central 1", region: "gcp-us-central1",
        provider: "gcp", gcp_project_id: "my-gcp-project",
        service_account_email: "clickgres@my-gcp-project.iam.gserviceaccount.com",
      ))
      location = Location.where(display_name: "GCP US Central 1").first
      expect(LocationCredentialGcp.count).to eq 1
      expect(LocationCredentialGcp[location.id]).to have_attributes(
        project_id: "my-gcp-project",
        service_account_email: "clickgres@my-gcp-project.iam.gserviceaccount.com",
      )
    end

    it "add_location for gcp provider updates an existing gcp credential" do
      location = Location.create(name: "gcp-us-central1", ui_name: "gcp-account", display_name: "GCP US Central 1", provider: "gcp", visible: true, project_id: nil)
      LocationCredentialGcp.create_with_id(location.id, project_id: "old-project", service_account_email: "old@old-project.iam.gserviceaccount.com", credentials_json: nil)
      UbicloudSetup.add_location(UbicloudSetup::LocationConfig.new(
        account_name: "gcp-account", name: "GCP US Central 1", region: "gcp-us-central1",
        provider: "gcp", gcp_project_id: "new-project",
        service_account_email: "new@new-project.iam.gserviceaccount.com",
      ))
      expect(LocationCredentialGcp.count).to eq 1
      expect(LocationCredentialGcp[location.id]).to have_attributes(
        project_id: "new-project",
        service_account_email: "new@new-project.iam.gserviceaccount.com",
      )
    end
  end

  describe ".visible_gcp_location_names" do
    it "returns gcp locations marked project_visible (defaulting to true), excluding hidden and non-gcp" do
      locations = [
        UbicloudSetup::LocationConfig.new(region: "gcp-us-central1", provider: "gcp", project_visible: true),
        UbicloudSetup::LocationConfig.new(region: "gcp-us-east4", provider: "gcp", project_visible: false),
        UbicloudSetup::LocationConfig.new(region: "gcp-us-west1", provider: "gcp"),
        UbicloudSetup::LocationConfig.new(region: "us-west-2", provider: "aws", project_visible: true),
      ]
      expect(UbicloudSetup.visible_gcp_location_names(locations)).to eq ["gcp-us-central1", "gcp-us-west1"]
    end
  end

  describe "with project and location" do
    let(:project_id) { UBID.generate UBID::TYPE_PROJECT }
    let(:postgres_service_hostname) { "pg.clickhouse-tests.com" }
    let(:project) do
      p = Project.new(name: "project-name")
      p.id = project_id.to_uuid
      p.save_changes
    end
    let(:location) { Location.create(name: "region", ui_name: "account_name", display_name: "test-location", provider: "aws", visible: true, project_id: nil, dns_suffix: "dns_suffix2") }
    let(:location_credential) { LocationCredentialAws.create_with_id(location.id, access_key: nil, secret_key: nil, assume_role: "role") }

    before do
      allow(Config).to receive(:dns_service_project_id).and_return(project.id).at_least(:once)
      allow(Validation).to receive(:validate_billing_rate).at_least(:once)
      allow(Prog::DnsZone::SetupDnsServerVm).to receive(:assemble)
    end

    it "fail on missing dns suffix" do
      expect(DnsServer.count).to eq 0
      expect(DnsZone.count).to eq 0
      expect {
        UbicloudSetup.setup_dns_for_location(project_id, UbicloudSetup::LocationConfig.new(account_name: "account_name", name: "test-location", region: "region", role: "role", dns_suffix: ""), vm_size: "m7i.large", boot_image: "ami-test123")
      }.to raise_error(RuntimeError, /no dns_suffix/)
      expect(DnsServer.count).to eq 0
      expect(DnsZone.count).to eq 0
    end

    it "add dns entries for location" do
      # Location.create(name: "region", ui_name: "account_name", display_name: "test-location", provider: "aws", visible: true, project_id: nil, dns_suffix: "dns_suffix2")
      expect(Config).to receive("postgres_service_hostname").at_least(:once).and_return(postgres_service_hostname)
      expect(DnsServer.count).to eq 0
      expect(DnsZone.count).to eq 0
      UbicloudSetup.setup_dns_for_location(project.id, UbicloudSetup::LocationConfig.new(account_name: location.ui_name, name: location.display_name, region: location.name, role: location_credential.assume_role, dns_suffix: location.dns_suffix), vm_size: "m7i.large", boot_image: "ami-test123")
      expect(DnsServer.count).to eq 1
      expect(DnsZone.count).to eq 1
      # Match Location, DNS Server and DnsZone 1:1
      location = Location.where(display_name: "test-location").first
      expect(DnsServer.where(name: "dns_suffix2").count).to eq 0
      # expect(DnsServer.first).to eq []
      expect(location.dns_suffix).to eq "dns_suffix2"
      dns_server = DnsServer.where(name: "dns_suffix2.pg.clickhouse-tests.com").first
      dns_zone = DnsZone.where(name: "dns_suffix2.pg.clickhouse-tests.com", project_id: project.id).first
      expect(dns_server).to have_attributes(
                            name: "dns_suffix2.pg.clickhouse-tests.com",
                          )
      expect(dns_zone).to have_attributes(
        name: "dns_suffix2.pg.clickhouse-tests.com",
        project_id: project.id,
      )
      expect(dns_server.dns_zones).to eq [dns_zone]
    end

    it "add dns zone for existing DNS server" do
      expect(Config).to receive("postgres_service_hostname").at_least(:once).and_return(postgres_service_hostname)
      dns_server = DnsServer.create(name: "dns_suffix2.pg.clickhouse-tests.com")
      expect(DnsZone.count).to eq 0
      expect(DnsServer.count).to eq 1
      UbicloudSetup.setup_dns_for_location(project.id, UbicloudSetup::LocationConfig.new(account_name: location.ui_name, name: location.display_name, region: location.name, role: location_credential.assume_role, dns_suffix: location.dns_suffix), vm_size: "m7i.large", boot_image: "ami-test123")
      expect(DnsZone.count).to eq 1
      expect(DnsServer.count).to eq 1
      dns_zone = DnsZone.where(name: "dns_suffix2.pg.clickhouse-tests.com", project_id: project.id).first
      expect(dns_zone).to have_attributes(
        name: "dns_suffix2.pg.clickhouse-tests.com",
        project_id: project.id,
      )
      expect(dns_server.dns_zones).to eq [dns_zone]
    end

    it "add existing DNS zones to existing DNS servers" do
      expect(Config).to receive("postgres_service_hostname").at_least(:once).and_return(postgres_service_hostname)
      dns_server = DnsServer.create(name: "dns_suffix2.pg.clickhouse-tests.com")
      dns_zone = DnsZone.create(name: "dns_suffix2.pg.clickhouse-tests.com", project_id: project.id)
      expect(DnsZone.count).to eq 1
      expect(DnsServer.count).to eq 1
      expect(dns_server.dns_zones.length).to eq 0
      UbicloudSetup.setup_dns_for_location(project.id, UbicloudSetup::LocationConfig.new(account_name: location.ui_name, name: location.display_name, region: location.name, role: location_credential.assume_role, dns_suffix: location.dns_suffix), vm_size: "m7i.large", boot_image: "ami-test123")
      expect(DnsZone.count).to eq 1
      expect(DnsServer.count).to eq 1
      expect(DnsServer.first).to eq dns_server
      expect(DnsZone.first).to eq dns_zone
      dns_server.reload
      expect(dns_server.dns_zones.length).to eq 1
    end

    it "create strand for existing dns zone and server" do
      expect(Config).to receive("postgres_service_hostname").at_least(:once).and_return(postgres_service_hostname)
      dns_server = DnsServer.create(name: "dns_suffix2.pg.clickhouse-tests.com")
      dns_zone = DnsZone.create(name: "dns_suffix2.pg.clickhouse-tests.com", project_id: project.id)
      dns_zone.add_dns_server dns_server
      expect(DnsZone.count).to eq 1
      expect(DnsServer.count).to eq 1
      expect(dns_server.dns_zones.length).to eq 1
      UbicloudSetup.setup_dns_for_location(project.id, UbicloudSetup::LocationConfig.new(account_name: location.ui_name, name: location.display_name, region: location.name, role: location_credential.assume_role, dns_suffix: location.dns_suffix), vm_size: "m7i.large", boot_image: "ami-test123")
      expect(DnsZone.count).to eq 1
      expect(DnsServer.count).to eq 1
      expect(dns_server.dns_zones).to eq [dns_zone]
      expect(dns_server.dns_zones.length).to eq 1
    end

    it "do not create strand for dns zone, server, strand existing" do
      expect(Config).to receive("postgres_service_hostname").at_least(:once).and_return(postgres_service_hostname)
      dns_server = DnsServer.create(name: "dns_suffix2.pg.clickhouse-tests.com")
      dns_zone = DnsZone.create(name: "dns_suffix2.pg.clickhouse-tests.com", project_id: project.id)
      dns_zone.add_dns_server dns_server
      strand = Strand.create_with_id(dns_zone.id, prog: "DnsZone::DnsZoneNexus", label: "wait")
      expect(DnsZone.count).to eq 1
      expect(DnsServer.count).to eq 1
      expect(dns_server.dns_zones).to eq [dns_zone]
      expect(dns_server.dns_zones.length).to eq 1
      UbicloudSetup.setup_dns_for_location(project.id, UbicloudSetup::LocationConfig.new(account_name: location.ui_name, name: location.display_name, region: location.name, role: location_credential.assume_role, dns_suffix: location.dns_suffix), vm_size: "m7i.large", boot_image: "ami-test123")
      expect(DnsZone.count).to eq 1
      expect(DnsServer.count).to eq 1
      expect(dns_server.dns_zones).to eq [dns_zone]
      expect(dns_server.dns_zones.length).to eq 1
      expect(Strand[dns_zone.id]).to eq strand
    end

    it "provisions VMs when count is below target" do
      expect(Config).to receive("postgres_service_hostname").at_least(:once).and_return(postgres_service_hostname)
      dns_server = DnsServer.create(name: "dns_suffix2.pg.clickhouse-tests.com")
      dns_zone = DnsZone.create(name: "dns_suffix2.pg.clickhouse-tests.com", project_id: project.id)
      dns_zone.add_dns_server dns_server

      expect(Prog::DnsZone::SetupDnsServerVm).to receive(:assemble).twice
        .with(dns_server, vm_size: "m7i.large", location_id: location.id, boot_image: "ami-test123", restrict_ssh_to_control_plane: true)
      UbicloudSetup.setup_dns_for_location(project.id, UbicloudSetup::LocationConfig.new(account_name: location.ui_name, name: location.display_name, region: location.name, role: location_credential.assume_role, dns_suffix: location.dns_suffix), vm_size: "m7i.large", boot_image: "ami-test123")
    end

    it "provisions gcp VMs with the caller-provided size and image" do
      gcp_location = Location.create(name: "gcp-us-central1", ui_name: "gcp-account", display_name: "GCP US Central 1", provider: "gcp", visible: true, project_id: nil, dns_suffix: "gcp-central")
      expect(Config).to receive("postgres_service_hostname").at_least(:once).and_return(postgres_service_hostname)

      expect(Prog::DnsZone::SetupDnsServerVm).to receive(:assemble).twice
        .with(an_instance_of(DnsServer), vm_size: "c4a-standard-4", location_id: gcp_location.id, boot_image: "ubuntu-noble", restrict_ssh_to_control_plane: true)
      UbicloudSetup.setup_dns_for_location(project.id, UbicloudSetup::LocationConfig.new(account_name: "gcp-account", name: "GCP US Central 1", region: "gcp-us-central1", provider: "gcp", dns_suffix: "gcp-central"), vm_size: "c4a-standard-4", boot_image: "ubuntu-noble")

      expect(DnsServer.where(name: "gcp-central.pg.clickhouse-tests.com").count).to eq 1
      expect(DnsZone.where(name: "gcp-central.pg.clickhouse-tests.com", project_id: project.id).count).to eq 1
    end

    it "does not provision VMs when target is already met" do
      expect(Config).to receive("postgres_service_hostname").at_least(:once).and_return(postgres_service_hostname)
      dns_server = DnsServer.create(name: "dns_suffix2.pg.clickhouse-tests.com")
      dns_zone = DnsZone.create(name: "dns_suffix2.pg.clickhouse-tests.com", project_id: project.id)
      dns_zone.add_dns_server dns_server

      # Create 2 VMs already associated with the DNS server
      2.times do |i|
        vm = Vm.create(
          family: "standard",
          cores: 1,
          name: "test-vm-#{i}",
          location:,
          arch: "x64",
          unix_user: "ubi",
          public_key: "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDPKr8KLN8F test@example.com",
          boot_image: "ubuntu-jammy",
          vcpus: 2,
          memory_gib: 4,
          project_id: project.id,
        )
        dns_server.add_vm(vm)
      end

      expect(Prog::DnsZone::SetupDnsServerVm).not_to receive(:assemble)
      UbicloudSetup.setup_dns_for_location(project.id, UbicloudSetup::LocationConfig.new(account_name: location.ui_name, name: location.display_name, region: location.name, role: location_credential.assume_role, dns_suffix: location.dns_suffix), vm_size: "m7i.large", boot_image: "ami-test123")
    end

    it "counts running strands towards target" do
      expect(Config).to receive("postgres_service_hostname").at_least(:once).and_return(postgres_service_hostname)
      dns_server = DnsServer.create(name: "dns_suffix2.pg.clickhouse-tests.com")
      dns_zone = DnsZone.create(name: "dns_suffix2.pg.clickhouse-tests.com", project_id: project.id)
      dns_zone.add_dns_server dns_server

      # Create 1 existing VM
      vm = Vm.create(
        family: "standard",
        cores: 1,
        name: "test-vm",
        location:,
        arch: "x64",
        unix_user: "ubi",
        public_key: "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDPKr8KLN8F test@example.com",
        boot_image: "ubuntu-jammy",
        vcpus: 2,
        memory_gib: 4,
        project_id: project.id,
      )
      dns_server.add_vm(vm)

      # Create 1 running strand
      Strand.create(prog: "DnsZone::SetupDnsServerVm", label: "start", stack: [{dns_server_id: dns_server.id}])

      # Should not provision any more VMs (1 existing + 1 running = 2 target)
      expect(Prog::DnsZone::SetupDnsServerVm).not_to receive(:assemble)
      UbicloudSetup.setup_dns_for_location(project.id, UbicloudSetup::LocationConfig.new(account_name: location.ui_name, name: location.display_name, region: location.name, role: location_credential.assume_role, dns_suffix: location.dns_suffix), vm_size: "m7i.large", boot_image: "ami-test123")
    end
  end

  def configs_dir
    File.join(__dir__, "configs")
  end

  def stub_setup_yaml_path(value)
    allow(ENV).to receive(:[]).and_call_original
    expect(ENV).to receive(:[]).at_least(:once).with("UBICLOUD_SETUP_YAML_PATH").and_return(value)
  end

  def stub_setup_yaml(filename)
    stub_setup_yaml_path(File.join(configs_dir, filename))
  end

  def stub_oidc_discovery(url)
    issuer = url.chomp("/")
    body = {
      issuer:,
      authorization_endpoint: "#{issuer}/o/oauth2/v2/auth",
      token_endpoint: "#{issuer}/token",
      userinfo_endpoint: "#{issuer}/v1/userinfo",
      jwks_uri: "#{issuer}/oauth2/v3/certs",
    }.to_json
    stub_request(:get, "#{issuer}/.well-known/openid-configuration")
      .to_return(status: 200, body:, headers: {"Content-Type" => "application/json"})
  end

  describe "setup_capacity_reservation" do
    let(:cr_loc) do
      Location.create(name: "us-west-2", ui_name: "cr-acct", display_name: "cr", provider: "aws", visible: true, project_id: nil)
    end

    def cr_config(enabled:, additional_capacity: 0.2)
      UbicloudSetup::LocationConfig.new(
        account_name: "cr-acct", name: "cr", region: "us-west-2", role: "role", dns_suffix: "c0",
        capacity_reservation: UbicloudSetup::CapacityReservationConfig.new(
          enabled:, enable_all_families: true, additional_capacity:,
        ),
      )
    end

    it "pauses an existing strand when the location is disabled, leaving it live and its ODCRs in place" do
      strand = Prog::CapacityReservation.assemble(location_id: cr_loc.id, instance_families: {}, additional_capacity: 0.2, enable_all_families: true)
      UbicloudSetup.setup_capacity_reservation(cr_config(enabled: false))
      expect(Semaphore.where(strand_id: strand.id, name: "pause").count).to eq(1)
      expect(Strand[strand.id]).not_to be_nil
      expect(Strand[strand.id].exitval).to be_nil
    end

    it "does not add a second pause when the disabled strand is already paused (idempotent across deploys)" do
      strand = Prog::CapacityReservation.assemble(location_id: cr_loc.id, instance_families: {}, additional_capacity: 0.2, enable_all_families: true)
      Semaphore.incr(strand.id, "pause")
      UbicloudSetup.setup_capacity_reservation(cr_config(enabled: false))
      expect(Semaphore.where(strand_id: strand.id, name: "pause").count).to eq(1)
    end

    it "resumes (clears pause) a previously-disabled location on re-enable and updates its inputs" do
      LocationCredentialAws.create_with_id(cr_loc.id, access_key: nil, secret_key: nil, assume_role: "role")
      strand = Prog::CapacityReservation.assemble(location_id: cr_loc.id, instance_families: {}, additional_capacity: 0.2, enable_all_families: true)
      Semaphore.incr(strand.id, "pause")
      expect(Semaphore.where(strand_id: strand.id, name: "pause").count).to eq(1)

      UbicloudSetup.setup_capacity_reservation(cr_config(enabled: true, additional_capacity: 0.45))

      expect(Semaphore.where(strand_id: strand.id, name: "pause").count).to eq(0)
      expect(strand.reload.stack.first["additional_capacity"]).to eq(0.45)
    end

    it "is a no-op for gcp locations (ODCRs are AWS-only)" do
      # enabled: true would create a live strand for a non-gcp location (see the
      # resume test above and the e2e us-west-2 assertion); the provider guard
      # short-circuits before that, so no strand is created.
      gcp_loc = Location.create(name: "gcp-us-central1", ui_name: "gcp-account", display_name: "GCP US Central 1", provider: "gcp", visible: true, project_id: nil)
      UbicloudSetup.setup_capacity_reservation(UbicloudSetup::LocationConfig.new(
        account_name: "gcp-account", name: "GCP US Central 1", region: "gcp-us-central1", provider: "gcp",
        capacity_reservation: UbicloudSetup::CapacityReservationConfig.new(enabled: true, enable_all_families: true, additional_capacity: 0.2),
      ))
      expect(Prog::CapacityReservation.live_strand(gcp_loc.id)).to be_nil
    end
  end

  describe "run_ch_ubi e2e" do
    let(:project_id) { UBID.generate UBID::TYPE_PROJECT }
    let(:project) do
      p = Project.new(name: "project-name")
      p.id = project_id.to_uuid
      p.save_changes
    end

    before do
      allow(Config).to receive(:dns_service_project_id).and_return(project.id).at_least(:once)
      allow(Validation).to receive(:validate_billing_rate).at_least(:once)
      allow(Prog::DnsZone::SetupDnsServerVm).to receive(:assemble)
      stub_oidc_discovery("https://accounts.google.com")
    end

    it "runs ubicloud setup" do
      stub_setup_yaml("setup_test.yaml")
      UbicloudSetup.run_ch_ubi
      expect(Account.count).to eq 2
      expect(Account.where(email: "observability-bot-test@clickhouse.com").count).to eq 1
      expect(ApiKey.count).to eq 2

      us_west_2 = Location.where(name: "us-west-2", ui_name: "dev-us-west-2-cell0-clickgres").first
      us_east_1 = Location.where(name: "us-east-1", ui_name: "dev-us-east-1-cell0-clickgres").first
      expect(OtelOtlpDestination[us_west_2.id]).to have_attributes(
        otlp_data_endpoint: "https://otel-data.example.com:4317",
        otlp_arrow_endpoint: "https://otel-arrow.example.com:4317",
        logs_endpoint: "https://otel-logs.example.com:4317",
        metrics_endpoint: "https://otel-metrics.example.com:4317",
        auth_audience: "https://otel.example.com",
      )
      expect(OtelOtlpDestination[us_east_1.id]).to be_nil

      # us-west-2 has capacity_reservation.enabled, us-east-1 does not.
      cr_strand = Prog::CapacityReservation.live_strand(us_west_2.id)
      expect(cr_strand).not_to be_nil
      expect(cr_strand.stack.first).to include("enable_all_families" => true, "additional_capacity" => 0.2, "allowed_capacity_decrease" => 0.3,
        "reconcile_interval" => 600, "remove_orphaned_reservations" => true, "min_available_az_insufficient_action" => "WARN")
      expect(Prog::CapacityReservation.live_strand(us_east_1.id)).to be_nil
    end

    it "fails on missing DNS Suffix" do
      stub_setup_yaml("setup_test_no_dns_suffix.yaml")
      expect { UbicloudSetup.run_ch_ubi }.to raise_error(RuntimeError, /no dns_suffix/)
    end

    it "fails for gcp locations without a dns_suffix" do
      stub_setup_yaml("setup_test_gcp.yaml")
      expect { UbicloudSetup.run_ch_ubi }.to raise_error(RuntimeError, /has no dns_suffix/)
    end

    it "creates gcp locations and gates UI visibility via project_visible" do
      stub_setup_yaml("setup_test_gcp_dns.yaml")
      UbicloudSetup.run_ch_ubi
      central = Location.where(name: "gcp-us-central1", ui_name: "dev-gcp-us-central1-clickgres").first
      east = Location.where(name: "gcp-us-east4", ui_name: "dev-gcp-us-east4-clickgres").first
      expect(central).not_to be_nil
      expect(central.provider).to eq "gcp"
      expect(central.dns_suffix).to eq "gcp-central"
      expect(LocationCredentialGcp[central.id]).to have_attributes(
        project_id: "my-gcp-project",
        service_account_email: "clickgres-cell@my-gcp-project.iam.gserviceaccount.com",
        credentials_json: nil,
      )
      expect(east).not_to be_nil
      expect(LocationCredentialGcp[east.id]).not_to be_nil
      # project_visible drives the per-project visible_postgres_locations ff (the gcp UI gate):
      # central is visible, east is not.
      project = Project.where(name: "clickgres-development").first
      expect(project.get_ff_visible_postgres_locations).to eq ["gcp-us-central1"]
      expect(project.gcp_dedicated_subnet_vpcs).to be true

      expect(PgGceImage.where(arch: "x64", gce_image_name: "postgres-ubuntu-2404-x64-20260218").first&.pg_versions).to eq(["16", "17", "18"])
      expect(PgGceImage.where(arch: "arm64", gce_image_name: "postgres-ubuntu-2404-arm64-20260218").first&.pg_versions).to eq(["16", "17", "18"])
    end

    it "provisions dns for gcp locations that declare a dns_suffix" do
      stub_setup_yaml("setup_test_gcp_dns.yaml")
      UbicloudSetup.run_ch_ubi
      central = Location.where(name: "gcp-us-central1", ui_name: "dev-gcp-us-central1-clickgres").first
      east = Location.where(name: "gcp-us-east4", ui_name: "dev-gcp-us-east4-clickgres").first
      expect(central.dns_suffix).to eq "gcp-central"
      expect(east.dns_suffix).to eq "gcp-east"

      [["gcp-central", central], ["gcp-east", east]].each do |suffix, loc|
        dns_hostname = "#{suffix}.#{Config.postgres_service_hostname}"
        expect(DnsServer.where(name: dns_hostname).count).to eq 1
        expect(DnsZone.where(name: dns_hostname).count).to eq 1
        expect(Prog::DnsZone::SetupDnsServerVm).to have_received(:assemble).twice
          .with(an_instance_of(DnsServer), vm_size: "c4a-standard-4", location_id: loc.id, boot_image: "ubuntu-noble", restrict_ssh_to_control_plane: true)
      end
    end

    it "no cleanup default locations" do
      stub_setup_yaml("setup_test_no_cleanup.yaml")
      expect(UbicloudSetup).not_to receive(:hide_default_locations)
      UbicloudSetup.run_ch_ubi
    end

    it "does not have pg amis ubicloud setup" do
      stub_setup_yaml("setup_test_no_ami.yaml")
      expect { UbicloudSetup.run_ch_ubi }.not_to raise_error
    end

    it "fails on missing dns_server_amis" do
      stub_setup_yaml("setup_test_no_dns_amis.yaml")
      expect { UbicloudSetup.run_ch_ubi }.to raise_error(/DNS AMI not configured/)
    end

    it "raises on missing path" do
      stub_setup_yaml_path("")
      expect { UbicloudSetup.run_ch_ubi }.to raise_error(RuntimeError, /UBICLOUD_SETUP_YAML_PATH environment variable is not set/)
    end

    it "sets up OIDC providers from config" do
      stub_setup_yaml("setup_test_with_oidc.yaml")
      expect(OidcProvider.count).to eq 0
      UbicloudSetup.run_ch_ubi
      expect(OidcProvider.count).to eq 1
      provider = OidcProvider["a1b2c3d4-e5f6-7890-abcd-ef1234567890"]
      expect(provider).not_to be_nil
      expect(provider.display_name).to eq "Test OIDC Provider"
    end

    it "skips OIDC setup when no oidc_providers in config" do
      stub_setup_yaml("setup_test_no_ami.yaml")
      UbicloudSetup.run_ch_ubi
      expect(OidcProvider.count).to eq 0
    end

    it "setup disabled should be noop" do
      stub_setup_yaml("setup_test_disabled.yaml")
      expect(UbicloudSetup).not_to receive(:setup_ubicloud)
      UbicloudSetup.run_ch_ubi
    end
  end

  describe "setup_config.schema.json" do
    require "json_schema"

    schema_path = File.expand_path("../../setup_config.schema.json", __dir__)
    schema = JsonSchema.parse!(JSON.parse(File.read(schema_path)))
    schema.expand_references!

    # Configs that should fail schema validation: their locations omit
    # dns_suffix, which both provider branches of the oneOf require.
    # setup_test_no_dns_suffix.yaml and setup_test_gcp.yaml were authored to
    # exercise the runtime dns_suffix-missing failure paths (aws and gcp
    # respectively); setup_test_disabled.yaml drives the `enabled: false`
    # no-op path and happens to also omit dns_suffix on its locations (those
    # locations are never read at runtime).
    location_one_of_failed = {type: :one_of_failed, message: /No subschema in "oneOf" matched/}
    invalid_configs = {
      "setup_test_no_dns_suffix.yaml" => [
        location_one_of_failed.merge(path: ["#", "locations", 0]),
        location_one_of_failed.merge(path: ["#", "locations", 1]),
      ],
      "setup_test_disabled.yaml" => [
        location_one_of_failed.merge(path: ["#", "locations", 0]),
        location_one_of_failed.merge(path: ["#", "locations", 1]),
      ],
      "setup_test_gcp.yaml" => [
        location_one_of_failed.merge(path: ["#", "locations", 0]),
        location_one_of_failed.merge(path: ["#", "locations", 1]),
      ],
    }

    Dir[File.join(__dir__, "configs", "setup_test*.yaml")].sort.each do |path|
      name = File.basename(path)
      if (expected_errors = invalid_configs[name])
        it "#{name} is intentionally invalid against the schema" do
          valid, errors = schema.validate(YAML.safe_load_file(path, permitted_classes: [], aliases: false))
          expect(valid).to be false
          expect(errors.size).to eq(expected_errors.size)
          errors.zip(expected_errors).each do |actual, expected|
            expect(actual).to have_attributes(type: expected[:type], path: expected[:path], message: match(expected[:message]))
          end
        end
      else
        it "#{name} is valid against the schema" do
          valid, errors = schema.validate(YAML.safe_load_file(path, permitted_classes: [], aliases: false))
          expect(valid).to be(true), -> { errors.map { |e| "#{e.path}: #{e.message}" }.join("\n") }
        end
      end
    end
  end
end
