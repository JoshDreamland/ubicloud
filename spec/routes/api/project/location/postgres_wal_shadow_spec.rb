# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "postgres wal-shadow" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  let(:pg) do
    Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: project.id,
      location_id: Location::HETZNER_FSN1_ID,
      name: "pg-ws",
      target_vm_size: "standard-2",
      target_storage_size_gib: 64,
      target_version: "17",
    ).subject
  end

  def base
    "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/wal-shadow"
  end

  def assemble_wal_shadow
    Prog::Postgres::PostgresWalShadowNexus.assemble(pg.id, ch_config: "[ch]\nurl = \"h\"\n", boot_image: "ami-1").subject
  end

  describe "unauthenticated" do
    it "cannot perform authenticated operations" do
      postgres_project = Project.create(name: "default")
      allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)

      [
        [:post, base],
        [:get, base],
        [:delete, base],
        [:get, "#{base}/status"],
        [:get, "#{base}/config"],
      ].each do |method, path|
        send method, path
        expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
      end
    end
  end

  describe "authenticated" do
    before do
      login_api
      postgres_project = Project.create(name: "default")
      allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)
      project.set_ff_postgres_wal_shadow(true)
    end

    describe "when the feature flag is disabled" do
      before { project.set_ff_postgres_wal_shadow(false) }

      it "returns 404" do
        get base
        expect(last_response).to have_api_error(404, "walshadow is not enabled for this project")
      end
    end

    describe "create" do
      it "creates a walshadow with a default git ref" do
        post base, {ch_config: "[ch]\nurl = \"h\"\n", boot_image: "ami-1"}.to_json

        expect(last_response.status).to eq(200)
        body = JSON.parse(last_response.body)
        expect(body["postgres_id"]).to eq pg.ubid
        expect(body["state"]).to eq "creating"
        expect(body["config"]).to eq({})
        ws = pg.reload.postgres_wal_shadow
        expect(ws.git_ref).to eq "main"
        expect(ws.base_ch_config).to eq "[ch]\nurl = \"h\"\n"
        expect(ws.strand.stack.first["boot_image"]).to eq "ami-1"
      end

      it "accepts an explicit git ref" do
        post base, {ch_config: "[ch]\n", boot_image: "ami-1", git_ref: "feature-branch"}.to_json

        expect(last_response.status).to eq(200)
        expect(pg.reload.postgres_wal_shadow.git_ref).to eq "feature-branch"
      end

      it "accepts explicit sizing and storage for durable state" do
        post base, {ch_config: "[ch]\n", boot_image: "ami-1", vm_size: "m8g.xlarge", storage_size_gib: 80, data_on_boot_volume: true}.to_json

        expect(last_response.status).to eq(200)
        ws = pg.reload.postgres_wal_shadow
        expect(ws.strand.stack.first["vm_size"]).to eq "m8g.xlarge"
        expect(ws.strand.stack.first["storage_size_gib"]).to eq 80
        expect(ws.data_on_boot_volume).to be true
      end

      it "accepts ephemeral state without a boot volume size" do
        post base, {ch_config: "[ch]\n", boot_image: "ami-1", vm_size: "m8gd.xlarge", data_on_boot_volume: false}.to_json

        expect(last_response.status).to eq(200)
        ws = pg.reload.postgres_wal_shadow
        expect(ws.strand.stack.first["vm_size"]).to eq "m8gd.xlarge"
        expect(ws.strand.stack.first["storage_size_gib"]).to eq PostgresWalShadow::DEFAULT_STORAGE_SIZE_GIB
        expect(ws.data_on_boot_volume).to be false
      end

      it "rejects storage_size_gib for ephemeral state" do
        post base, {ch_config: "[ch]\n", boot_image: "ami-1", vm_size: "m8gd.xlarge", storage_size_gib: 80, data_on_boot_volume: false}.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: storage_size_gib")
      end

      it "rejects a second walshadow" do
        assemble_wal_shadow
        post base, {ch_config: "[ch]\n", boot_image: "ami-1"}.to_json
        expect(last_response).to have_api_error(400, "walshadow already exists for this database")
      end
    end

    describe "show" do
      it "returns the serialized walshadow" do
        ws = assemble_wal_shadow
        get base
        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["id"]).to eq ws.ubid
      end

      it "returns 404 when missing" do
        get base
        expect(last_response.status).to eq(404)
      end
    end

    describe "delete" do
      it "schedules destruction" do
        ws = assemble_wal_shadow
        delete base
        expect(last_response.status).to eq(204)
        expect(SemSnap.new(ws.id).set?("destroy")).to be true
      end

      it "is a no-op when missing" do
        delete base
        expect(last_response.status).to eq(204)
      end
    end

    describe "status" do
      it "returns the cached status snapshot" do
        ws = assemble_wal_shadow
        ws.update(status: {"paused" => true, "rows_synced" => 10, "backfills_pending" => 0, "lag_bytes" => 5, "lag_seconds" => 1, "uptime_secs" => 99}, status_at: Time.now)
        get "#{base}/status"
        expect(last_response.status).to eq(200)
        body = JSON.parse(last_response.body)
        expect(body["paused"]).to be true
        expect(body["rows_synced"]).to eq 10
        expect(body["refreshed_at"]).not_to be_nil
      end

      it "returns null fields before the first refresh" do
        assemble_wal_shadow
        get "#{base}/status"
        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["paused"]).to be_nil
      end

      it "returns 404 when missing" do
        get "#{base}/status"
        expect(last_response.status).to eq(404)
      end
    end

    describe "config" do
      it "returns the config" do
        ws = assemble_wal_shadow
        ws.update(api_ch_config: JSON.generate({"ch" => {"url" => "http://ch", "password" => "secret"}}))
        get "#{base}/config"
        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)).to eq({"config" => {"ch" => {"url" => "http://ch", "password" => "secret"}}})
      end

      it "returns 404 when missing" do
        get "#{base}/config"
        expect(last_response.status).to eq(404)
      end

      it "deep-merges a config" do
        ws = assemble_wal_shadow
        patch "#{base}/config", {config: {ch: {url: "http://ch", password: "secret", secure: true}}}.to_json
        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)).to eq({"config" => {"ch" => {"url" => "http://ch", "password" => "secret", "secure" => true}}})
        expect(ws.reload.api_config_hash["ch"]["password"]).to eq "secret"
        expect(SemSnap.new(ws.id).set?("update_config")).to be true
      end

      it "rejects source edits" do
        assemble_wal_shadow
        patch "#{base}/config", {config: {source: {host: "x"}}}.to_json
        expect(last_response).to have_api_error(400, "walshadow [source] is derived from the database and cannot be edited via the API")
      end

      it "rejects non-scalar values" do
        assemble_wal_shadow
        patch "#{base}/config", {config: {ch: {hosts: [1, 2]}}}.to_json
        expect(last_response).to have_api_error(400, "walshadow config values must be strings, numbers, or booleans")
      end

      it "returns 404 on patch when missing" do
        patch "#{base}/config", {config: {ch: {url: "x"}}}.to_json
        expect(last_response.status).to eq(404)
      end

      it "unsets keys" do
        ws = assemble_wal_shadow
        ws.update(api_ch_config: JSON.generate({"ch" => {"url" => "http://ch"}, "stream" => {"paused" => true}}))
        delete "#{base}/config", {keys: ["stream.paused"]}.to_json
        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)).to eq({"config" => {"ch" => {"url" => "http://ch"}}})
      end

      it "is a no-op unset when missing" do
        delete "#{base}/config", {keys: ["stream.paused"]}.to_json
        expect(last_response.status).to eq(204)
      end
    end
  end
end
