# frozen_string_literal: true

require "excon"
require "json"

# Client for the Archil control-plane REST API (https://docs.archil.com).
class ArchilClient
  # Raised when the API answers with its failure envelope ({success: false,
  # error:, code:}). code carries the vendor's stable machine-readable error
  # code when one was given.
  class Error < StandardError
    attr_reader :code

    def initialize(message, code: nil)
      @code = code
      super(message)
    end
  end

  # Raised by create_disk when a disk with the requested name already exists:
  # either the configuration differs (HTTP 409), or it matches (HTTP 200)
  # but the one-time mount token from the original creation can no longer be
  # read. Callers self-heal by finding the disk with list_disks and minting
  # a fresh credential with create_disk_user.
  class AlreadyExists < Error; end

  # Control-plane cells differ by provider: every AWS region lives in a
  # "green" cell while GCP's lives in "blue", so hosts are mapped explicitly
  # instead of derived from the region name.
  REGION_URLS = {
    "aws-us-east-1" => "https://control.green.us-east-1.aws.prod.archil.com",
    "aws-us-west-2" => "https://control.green.us-west-2.aws.prod.archil.com",
    "aws-eu-west-1" => "https://control.green.eu-west-1.aws.prod.archil.com",
    "gcp-us-central1" => "https://control.blue.us-central1.gcp.prod.archil.com",
  }.freeze

  # API keys are region-scoped; the control-plane host embeds the region.
  def self.control_plane_host(archil_region)
    REGION_URLS.fetch(archil_region) { fail "Unknown Archil region: #{archil_region}" }
  end

  def initialize(archil_region, api_key: Config.archil_api_key)
    fail "No Archil API key is configured" unless api_key
    # Keys are issued with a "key-" prefix that pasted configs sometimes
    # lose; strip-then-add so both spellings authenticate.
    authorization = "key-#{api_key.delete_prefix("key-")}"
    @connection = Excon.new(self.class.control_plane_host(archil_region),
      headers: {"Content-Type" => "application/json", "Authorization" => authorization, "User-Agent" => "ubicloud"},
      connect_timeout: 30, read_timeout: 30)
  end

  # Returns {disk_id:, token:, token_identifier:}. The token is the disk's
  # default mount credential and is returned exactly once by the API; the
  # caller must immediately persist it and the identifier that can later
  # revoke it.
  def create_disk(name)
    response = @connection.post(path: "/api/disks", body: {name:}.to_json, expects: [200, 201])
    data = unwrap(response)
    disk_id = data.fetch("diskId")
    token_user = data.fetch("authorizedUsers").find { it["type"] == "token" }
    unless token_user&.key?("token")
      # 200 rather than 201 means a disk with this name already existed with
      # a matching configuration; its one-time token cannot be read again.
      # Surface it like the 409 name conflict so the caller self-heals.
      raise AlreadyExists.new("Archil disk #{name} already exists as #{disk_id}") if response.status == 200
      fail "Archil disk #{disk_id} was created without a token user"
    end
    {disk_id:, token: token_user.fetch("token"), token_identifier: token_user["identifier"]}
  rescue Excon::Error::Conflict => e
    body = parse_envelope(e.response.body)
    raise AlreadyExists.new(body["error"] || "Archil disk #{name} already exists", code: body["code"])
  end

  # The disk's detail record. Usage consumers read the documented
  # "activeDataBytes" (bytes active in the high-speed cache) and
  # "totalDataBytes" (total logical bytes written) fields — those names are
  # the contract with callers; no other usage field exists in any response.
  def get_disk(disk_id)
    response = @connection.get(path: "/api/disks/#{disk_id}", expects: 200)
    unwrap(response)
  end

  # All disks visible to the api key, so a reconciler can discover vendor
  # disks whose control-plane row was lost (or never got its disk_id).
  # Assumes the single response is complete: no pagination shape has been
  # observed in live responses, and the daily reconciler (the main consumer)
  # tolerates under-listing — it deletes only disks its own rows orphaned,
  # never anything it merely fails to see. Revisit at fleet scale.
  def list_disks
    response = @connection.get(path: "/api/disks", expects: 200)
    unwrap(response)
  end

  # Deleting an already-deleted disk is a success: destroy must be idempotent.
  def delete_disk(disk_id)
    response = @connection.delete(path: "/api/disks/#{disk_id}", expects: [200, 404])
    unwrap(response) unless response.status == 404
    nil
  end

  # Mints an additional mount credential (a vendor "token user") for the
  # disk, so every VM mounting the disk can hold its own, individually
  # revocable credential instead of sharing the disk's root token. Returns
  # {token:, identifier:}: the token is shown exactly once, the identifier
  # is the stable handle delete_disk_user revokes by.
  def create_disk_user(disk_id, nickname:)
    response = @connection.post(path: "/api/disks/#{disk_id}/users", body: {type: "token", nickname:}.to_json, expects: 201)
    data = unwrap(response)
    {token: data.fetch("token"), identifier: data.fetch("identifier")}
  end

  # Revokes a mount credential minted by create_disk_user. Revoking an
  # already-removed credential is a success: destroy must be idempotent.
  def delete_disk_user(disk_id, identifier:)
    response = @connection.delete(path: "/api/disks/#{disk_id}/users/token", query: {identifier:}, expects: [200, 404])
    unwrap(response) unless response.status == 404
    nil
  end

  def list_branches(disk_id)
    response = @connection.get(path: "/api/disks/#{disk_id}/branches", expects: 200)
    unwrap(response)
  end

  # Forks a checkpoint into a writable branch in the disk's namespace (the
  # disk's mount tokens only authorize branches of the disk itself, so nested
  # branches must land here too). from_branch scopes the checkpoint lookup
  # when the checkpoint was taken on a branch rather than on the disk root —
  # the REST equivalent of the CLI's --from-branch.
  def create_branch(disk_id, branch_name:, from_checkpoint_name:, from_branch: nil)
    body = {branch_name:, from_checkpoint_name:}
    body[:from_branch] = from_branch if from_branch
    response = @connection.post(path: "/api/disks/#{disk_id}/branches", body: body.to_json, expects: [200, 201])
    unwrap(response)
  end

  # Checkpoints in the disk's namespace; branch scopes the listing to the
  # checkpoints taken on that branch instead of the disk root.
  def list_checkpoints(disk_id, branch: nil)
    query = branch ? {branch:} : nil
    response = @connection.get(path: "/api/disks/#{disk_id}/checkpoints", query:, expects: 200)
    unwrap(response)
  end

  # Every response wears the vendor envelope: success plus data on success,
  # success false plus error/code on failure. A 2xx status with success
  # false is still a failure; surface the vendor's message and code instead
  # of misreading the payload.
  private def unwrap(response)
    body = parse_envelope(response.body)
    unless body["success"]
      raise Error.new(body["error"] || "Archil API request failed (status #{response.status})", code: body["code"])
    end
    body["data"]
  end

  # A body that isn't the JSON envelope (a proxy error page, a truncated
  # response) must surface as a typed Error, not a JSON::ParserError or
  # NoMethodError that no caller rescues.
  private def parse_envelope(body)
    parsed = begin
      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end
    parsed.is_a?(Hash) ? parsed : {}
  end
end
