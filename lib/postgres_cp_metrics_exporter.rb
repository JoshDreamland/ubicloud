# frozen_string_literal: true

require "excon"
require "jwt"

# Exports the control plane's own Postgres observations (currently the
# pg_cp_up liveness pulse) from the postgres_int_metric_monitor table to the
# regional OTLP collectors, giving the instance-down alarm a witness
# independent of the database VM. Each row is one (server, metric) gauge.
# Called from a single respirate strand; a failed batch is retried on the
# next run and can only ever delay an alarm, never cause one.
class PostgresCpMetricsExporter
  SEND_TIMEOUT_SECONDS = 10

  def self.export
    SINGLETON.export
  end

  def initialize
    @tokens = {}
  end

  # Pushes the full current state, one point per (server, metric), on every
  # run. Regional batches are sent on parallel threads so one hung collector
  # cannot delay the rest; tokens are minted here on the calling thread, so
  # the token cache is never accessed concurrently. A failed batch is logged
  # and dropped; the next run resends the full state anyway, so resends are
  # the retry mechanism. Points carry the row's observed_at, so an unchanged
  # row re-sends the same timestamp and never fabricates freshness.
  def export
    rows = POSTGRES_MONITOR_DB[:postgres_int_metric_monitor].all
    return if rows.empty?

    batches(rows).filter_map do |destination, entries|
      token = token_for(destination.auth_audience)
      Thread.new do
        send_batch(destination, entries, token)
      rescue => ex
        Clog.emit("postgres cp metrics batch send failed", Util.exception_to_hash(ex, into: {metrics_endpoint: destination.metrics_endpoint, auth_audience: destination.auth_audience}))
      end
    rescue => ex
      Clog.emit("postgres cp metrics batch send failed", Util.exception_to_hash(ex, into: {metrics_endpoint: destination.metrics_endpoint, auth_audience: destination.auth_audience}))
      nil
    end.each(&:join)
  end

  private

  def batches(rows)
    by_server_id = rows.group_by { it[:postgres_server_id] }
    servers = PostgresServer.where(id: by_server_id.keys).eager(resource: {location: :otel_otlp_destination}).all
    servers.reject { it.resource.nil? }
      .group_by { it.resource.location.otel_otlp_destination }
      .reject { |destination, _| destination.nil? }
      .map { |destination, group| [destination, group.map { [it, by_server_id[it.id]] }] }
  end

  def send_batch(destination, entries, token)
    Excon.post(
      "#{destination.metrics_endpoint}/v1/metrics",
      headers: {
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{token}",
      },
      body: JSON.generate(resourceMetrics: entries.map { |server, rows| resource_metrics(server, rows) }),
      connect_timeout: SEND_TIMEOUT_SECONDS,
      write_timeout: SEND_TIMEOUT_SECONDS,
      read_timeout: SEND_TIMEOUT_SECONDS,
      expects: [200],
    )
  end

  def resource_metrics(server, rows)
    attributes = {
      "ubi.postgres_resource_uuid" => server.resource.id,
      "ubi.postgres_resource_ubid" => server.resource.ubid,
      "ubi.postgres_server_ubid" => server.ubid,
      "ubi.postgres_server_role" => server.is_representative ? "primary" : "standby",
    }
    {
      resource: {attributes: attributes.map { |key, value| {key:, value: {stringValue: value}} }},
      scopeMetrics: [{metrics: rows.map { |row|
        {
          name: row[:metric_name],
          gauge: {dataPoints: [{
            timeUnixNano: (row[:observed_at].to_r * 1_000_000_000).to_i.to_s,
            asInt: row[:value].to_s,
          }]},
        }
      }}],
    }
  end

  # TODO: extract this cache into OidcProvider once a second caller needs
  # cached client-credentials tokens (clover_freeze freezes class objects,
  # so it needs the same eager-singleton pattern used here).
  def token_for(audience)
    cached = @tokens[audience]
    return cached[:token] if cached && Time.now.to_i < cached[:refresh_at]

    token = mint_token(audience)
    refresh_at = refresh_at(token)
    @tokens[audience] = {token:, refresh_at:} if Time.now.to_i < refresh_at
    token
  end

  def mint_token(audience)
    oidc_provider_id = Config.postgres_cp_metrics_oidc_provider_id
    oidc_provider = oidc_provider_id && OidcProvider[oidc_provider_id]
    raise "postgres_cp_metrics_oidc_provider_id does not correspond to an existing OidcProvider" unless oidc_provider

    oidc_provider.client_credentials_token(audience:, timeout: SEND_TIMEOUT_SECONDS)
  end

  # Refresh at two-thirds of the token lifetime, matching the VM token path.
  # An undecodable token is used once but never cached.
  def refresh_at(token)
    payload, _header = JWT.decode(token, nil, false)
    payload.fetch("iat") + (payload.fetch("exp") - payload.fetch("iat")) * 2 / 3
  rescue JWT::DecodeError, KeyError
    0
  end

  # Created eagerly so no state lives on the class object, which clover_freeze
  # freezes in production; the instance itself stays mutable.
  SINGLETON = new
end
