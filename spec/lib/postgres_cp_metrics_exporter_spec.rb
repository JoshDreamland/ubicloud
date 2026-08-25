# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe PostgresCpMetricsExporter do
  subject(:exporter) { described_class.new }

  let(:project) { Project.create(name: "postgres-service") }
  let(:location) { Location::HETZNER_FSN1_ID }
  let(:resource) { create_postgres_resource(project:, location_id: location) }
  let(:primary) { create_postgres_server(resource:) }
  let(:standby) { create_postgres_server(resource:, is_representative: false) }
  let(:token) { JWT.encode({iat: Time.now.to_i, exp: Time.now.to_i + 3600}, nil, "none") }
  let(:oidc_provider) {
    OidcProvider.create(
      display_name: "cp-metrics", url: "https://auth.example.com",
      authorization_endpoint: "/authorize", token_endpoint: "/oauth/token",
      userinfo_endpoint: "/userinfo", jwks_uri: "https://auth.example.com/jwks",
      client_id: "cp-monitor", client_secret: "secret",
    )
  }

  def create_destination(location_id: location, metrics_endpoint: "https://otel.example.com")
    OtelOtlpDestination.create_with_id(
      Location[location_id],
      otlp_data_endpoint: "https://otel.example.com", otlp_arrow_endpoint: "https://otel.example.com",
      logs_endpoint: "https://otel.example.com",
      metrics_endpoint:, auth_audience: "https://otel-audience.example.com",
    )
  end

  def stub_token_endpoint(access_token: token)
    stub_request(:post, "https://auth.example.com/oauth/token")
      .to_return(status: 200, body: JSON.generate(access_token:), headers: {"Content-Type" => "application/json"})
  end

  def stub_otlp(metrics_endpoint: "https://otel.example.com", status: 200)
    @otlp_requests = []
    stub_request(:post, "#{metrics_endpoint}/v1/metrics")
      .with { |request| @otlp_requests << request }
      .to_return(status:)
  end

  def insert_pulse(server, value, observed_at, metric_name: "pg_cp_up")
    POSTGRES_MONITOR_DB[:postgres_int_metric_monitor]
      .insert_conflict(target: [:postgres_server_id, :metric_name], update: {value: Sequel[:excluded][:value], observed_at: Sequel[:excluded][:observed_at]})
      .insert(postgres_server_id: server.id, metric_name:, value:, observed_at:)
  end

  before do
    allow(Config).to receive(:postgres_cp_metrics_oidc_provider_id).and_return(oidc_provider.id)
    # SINGLETON's token cache outlives any one example, so ".export" specs
    # (which exercise it) must not leak a cached token into the next example.
    described_class::SINGLETON.instance_variable_set(:@tokens, {})
  end

  # POSTGRES_MONITOR_DB doesn't use transactional testing, so it must be manually cleaned up
  after do
    POSTGRES_MONITOR_DB[:postgres_int_metric_monitor].delete
  end

  describe ".export" do
    before do
      create_destination
      stub_token_endpoint
    end

    it "sends nothing when the table is empty" do
      described_class.export
      expect(WebMock).not_to have_requested(:post, "https://otel.example.com/v1/metrics")
    end

    it "pushes every row on every run, changed or not" do
      observed_at = Time.now.round(6)
      insert_pulse(primary, 1, observed_at)
      otlp = stub_otlp
      described_class.export
      described_class.export
      expect(otlp).to have_been_requested.twice
      body = JSON.parse(@otlp_requests.last.body)
      data_point = body["resourceMetrics"][0]["scopeMetrics"][0]["metrics"][0]["gauge"]["dataPoints"][0]
      expect(data_point["asInt"]).to eq("1")
      expect(data_point["timeUnixNano"]).to eq((observed_at.to_r * 1_000_000_000).to_i.to_s)
    end

    it "builds one resource entry per server with the attributes the reporter keys on" do
      observed_at = Time.now.round(6)
      insert_pulse(primary, 1, observed_at)
      insert_pulse(standby, 0, observed_at)
      otlp = stub_otlp
      described_class.export

      expect(otlp).to have_been_requested.once
      request = @otlp_requests.last
      expect(request.headers["Authorization"]).to eq("Bearer #{token}")
      body = JSON.parse(request.body)
      by_ubid = body["resourceMetrics"].to_h { |rm|
        attributes = rm["resource"]["attributes"].to_h { [it["key"], it["value"]["stringValue"]] }
        [attributes["ubi.postgres_server_ubid"], {attributes:, metric: rm["scopeMetrics"][0]["metrics"][0]}]
      }
      expect(by_ubid.keys).to contain_exactly(primary.ubid, standby.ubid)
      expect(by_ubid[primary.ubid][:attributes]).to eq(
        "ubi.postgres_resource_uuid" => resource.id,
        "ubi.postgres_resource_ubid" => resource.ubid,
        "ubi.postgres_server_ubid" => primary.ubid,
        "ubi.postgres_server_role" => "primary",
      )
      expect(by_ubid[standby.ubid][:attributes]["ubi.postgres_server_role"]).to eq("standby")
      expect(by_ubid[primary.ubid][:metric]["name"]).to eq("pg_cp_up")
      expect(by_ubid[primary.ubid][:metric]["gauge"]["dataPoints"][0]["asInt"]).to eq("1")
      expect(by_ubid[standby.ubid][:metric]["gauge"]["dataPoints"][0]["asInt"]).to eq("0")
    end

    it "sends all of a server's metrics in one resource entry" do
      observed_at = Time.now.round(6)
      insert_pulse(primary, 1, observed_at)
      insert_pulse(primary, 42, observed_at, metric_name: "pg_cp_other")
      stub_otlp
      described_class.export

      metrics = JSON.parse(@otlp_requests.last.body)["resourceMetrics"][0]["scopeMetrics"][0]["metrics"]
      expect(metrics.to_h { [it["name"], it["gauge"]["dataPoints"][0]["asInt"]] })
        .to eq("pg_cp_up" => "1", "pg_cp_other" => "42")
    end

    it "silently skips rows for servers that no longer exist or have no destination" do
      destinationless = create_postgres_server(resource: create_postgres_resource(project:, location_id: Location::HETZNER_HEL1_ID))
      orphan = create_postgres_server(resource: create_postgres_resource(project:, location_id: location))
      orphan.this.update(resource_id: "e9d3f5a1-0000-4000-8000-000000000001")
      orphan.reload
      insert_pulse(destinationless, 1, Time.now)
      insert_pulse(orphan, 1, Time.now)
      POSTGRES_MONITOR_DB[:postgres_int_metric_monitor].insert(postgres_server_id: "2d720de9-8e52-8501-a705-2e5d41f5a2ba", metric_name: "pg_cp_up", value: 1, observed_at: Time.now)
      expect { described_class.export }.not_to raise_error
      expect(WebMock).not_to have_requested(:post, "https://otel.example.com/v1/metrics")
    end

    it "keeps serving other locations when one destination fails" do
      other_server = create_postgres_server(resource: create_postgres_resource(project:, location_id: Location::HETZNER_HEL1_ID))
      create_destination(location_id: Location::HETZNER_HEL1_ID, metrics_endpoint: "https://otel-other.example.com")
      stub_request(:post, "https://otel-other.example.com/v1/metrics").to_timeout
      otlp = stub_otlp

      insert_pulse(primary, 1, Time.now)
      insert_pulse(other_server, 1, Time.now)
      expect(Clog).to receive(:emit).with("postgres cp metrics batch send failed", hash_including(metrics_endpoint: "https://otel-other.example.com")).and_call_original
      described_class.export
      expect(otlp).to have_been_requested.once
    end
  end

  describe "token handling" do
    before do
      create_destination
      stub_otlp
    end

    it "caches the token per audience until two-thirds of its lifetime" do
      minting = stub_token_endpoint
      insert_pulse(primary, 1, Time.now)
      exporter.export
      exporter.export
      expect(minting).to have_been_requested.once
    end

    it "re-mints once two-thirds of the token lifetime has passed" do
      stale = JWT.encode({iat: Time.now.to_i - 100, exp: Time.now.to_i + 10}, nil, "none")
      minting = stub_token_endpoint(access_token: stale)
      insert_pulse(primary, 1, Time.now)
      exporter.export
      exporter.export
      expect(minting).to have_been_requested.twice
    end

    it "uses an undecodable token but does not cache it" do
      minting = stub_token_endpoint(access_token: "garbage")
      insert_pulse(primary, 1, Time.now)
      exporter.export
      expect(WebMock).to have_requested(:post, "https://otel.example.com/v1/metrics")
        .with(headers: {"Authorization" => "Bearer garbage"}).once
      exporter.export
      expect(minting).to have_been_requested.twice
    end

    it "drops the batch with a log when no OidcProvider is configured" do
      allow(Config).to receive(:postgres_cp_metrics_oidc_provider_id).and_return(nil)
      insert_pulse(primary, 1, Time.now)
      expect(Clog).to receive(:emit).with("postgres cp metrics batch send failed", anything).and_call_original
      exporter.export
      expect(WebMock).not_to have_requested(:post, "https://otel.example.com/v1/metrics")
    end
  end
end
