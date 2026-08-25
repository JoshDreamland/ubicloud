# frozen_string_literal: true

require_relative "../../../model/spec_helper"

RSpec.describe PostgresServer::PrependMethods do # rubocop:disable RSpec/SpecFilePathFormat
  subject(:postgres_server) {
    PostgresServer.create(
      timeline:, resource:, vm_id: vm.id, is_representative: true,
      synchronization_status: "ready", timeline_access: "push", version: "16",
    )
  }

  let(:project) { Project.create(name: "postgres-server") }
  let(:project_service) { Project.create(name: "postgres-service") }
  let(:timeline) { create_postgres_timeline(location_id: location.id) }
  let(:resource) { create_postgres_resource(project:, location_id: location.id) }
  let(:private_subnet) {
    PrivateSubnet.create(
      name: "postgres-subnet", project:, location:,
      net4: NetAddr::IPv4Net.parse("172.0.0.0/26"),
      net6: NetAddr::IPv6Net.parse("fdfa:b5aa:14a3:4a3d::/64"),
    )
  }
  let(:vm) { create_hosted_vm(project, private_subnet, "dummy-vm") }
  let(:location) {
    Location.create(
      name: "us-west-2", project:, display_name: "us-west-2", ui_name: "us-west-2",
      provider: "ubicloud", visible: true,
    )
  }

  before do
    allow(Config).to receive(:postgres_service_project_id).and_return(project_service.id)
    resource.update(flavor: PostgresResource::Flavor::STANDARD, cert_auth_users: [])
    MinioCluster.create(
      project_id: Config.postgres_service_project_id, location:, name: "pgminio",
      admin_user: "root", admin_password: "root",
    )
  end

  describe "#pg_stat_ch_extra_attributes" do
    it "renders instance_ubid, server_ubid, server_role, region, host_id" do
      value = postgres_server.pg_stat_ch_extra_attributes
      pairs = value.split(";").to_h { it.split(":", 2) }
      expect(pairs).to include(
        "instance_ubid" => resource.ubid,
        "server_ubid" => postgres_server.ubid,
        "server_role" => "primary",
        "read_replica_type" => "none",
        "region" => location.name,
      )
      expect(pairs).to have_key("host_id")
    end

    it "marks server_role as standby when timeline_access is fetch" do
      postgres_server.timeline_access = "fetch"
      expect(postgres_server.pg_stat_ch_extra_attributes).to include("server_role:standby")
    end

    it "uses aws_instance.instance_id for host_id on AWS-backed VMs" do
      aws_instance = instance_double(AwsInstance, instance_id: "i-0abcd1234ef567890")
      expect(postgres_server.vm).to receive(:aws_instance).and_return(aws_instance).at_least(:once)
      expect(postgres_server.pg_stat_ch_extra_attributes).to include("host_id:i-0abcd1234ef567890")
    end

    it "marks read_replica_type regional when the resource has a parent" do
      parent = create_postgres_resource(project:, location_id: location.id)
      resource.update(parent_id: parent.id)
      expect(postgres_server.pg_stat_ch_extra_attributes).to include("read_replica_type:regional")
    end
  end

  describe "#configure_hash" do
    it "appends pg_stat_ch.extra_attributes to the base configs hash, single-quoted" do
      value = postgres_server.configure_hash[:configs]["pg_stat_ch.extra_attributes"]
      expect(value).to start_with("'").and end_with("'")
      expect(value[1..-2]).to eq(postgres_server.pg_stat_ch_extra_attributes)
    end

    it "appends pg_stat_ch.queue_capacity sized by vCPU tier" do
      value = postgres_server.configure_hash[:configs]["pg_stat_ch.queue_capacity"]
      expect(value).to eq(postgres_server.pg_stat_ch_queue_capacity.to_s)
    end

    it "appends pg_stat_ch.string_area_size sized by vCPU tier" do
      value = postgres_server.configure_hash[:configs]["pg_stat_ch.string_area_size"]
      expect(value).to eq(postgres_server.pg_stat_ch_string_area_size.to_s)
    end

    it "enables pg_stat_ch.otel_arrow_passthrough so the bgworker emits Arrow IPC batches" do
      expect(postgres_server.configure_hash[:configs]["pg_stat_ch.otel_arrow_passthrough"]).to eq("on")
    end

    it "does not set pg_stat_ch.otel_log_queue_size (kept at compile default)" do
      expect(postgres_server.configure_hash[:configs]).not_to have_key("pg_stat_ch.otel_log_queue_size")
    end

    it "appends pg_stat_ch to shared_preload_libraries for standard flavor" do
      expect(postgres_server.configure_hash[:configs]["shared_preload_libraries"]).to eq("'pg_cron,pg_stat_statements,pg_stat_ch'")
    end

    it "leaves shared_preload_libraries untouched for non-standard flavors" do
      resource.update(flavor: PostgresResource::Flavor::LANTERN)
      base_method = postgres_server.method(:configure_hash).super_method
      base_libs = base_method.call[:configs]["shared_preload_libraries"]
      expect(postgres_server.configure_hash[:configs]["shared_preload_libraries"]).to eq(base_libs)
      expect(postgres_server.configure_hash[:configs]["shared_preload_libraries"]).not_to include("pg_stat_ch")
    end

    it "overrides the base configure_hash" do
      base_method = postgres_server.method(:configure_hash).super_method
      expect(base_method).not_to be_nil
      base_configs = base_method.call[:configs]
      expect(base_configs).not_to have_key("pg_stat_ch.extra_attributes")
    end
  end

  describe "#pg_stat_ch_queue_capacity" do
    {2 => 262_144, 4 => 524_288, 8 => 1_048_576, 16 => 2_097_152}.each do |vcpus, expected|
      it "returns #{expected} for a #{vcpus}-vCPU VM" do
        allow(postgres_server.vm).to receive(:vcpus).and_return(vcpus)
        expect(postgres_server.pg_stat_ch_queue_capacity).to eq(expected)
      end
    end
  end

  describe "#pg_stat_ch_string_area_size" do
    {2 => 64, 4 => 128, 8 => 256, 16 => 512}.each do |vcpus, expected|
      it "returns #{expected} MB for a #{vcpus}-vCPU VM" do
        allow(postgres_server.vm).to receive(:vcpus).and_return(vcpus)
        expect(postgres_server.pg_stat_ch_string_area_size).to eq(expected)
      end
    end
  end

  describe "#check_pulse" do
    let(:session) { {ssh_session: Net::SSH::Connection::Session.allocate, db_connection: DB} }

    def pulse_row
      POSTGRES_MONITOR_DB[:postgres_int_metric_monitor].where(postgres_server_id: postgres_server.id).first
    end

    before { allow(Config).to receive(:postgres_cp_metrics_export_enabled).and_return(true) }

    # POSTGRES_MONITOR_DB is a separate Sequel connection not covered by the
    # suite's rollback transaction, so rows must be cleaned explicitly;
    # reruns otherwise hit unique-constraint violations.
    after { POSTGRES_MONITOR_DB[:postgres_int_metric_monitor].delete }

    it "records an up reading on the first pulse" do
      expect(postgres_server.check_pulse(session:, previous_pulse: {})[:reading]).to eq("up")
      expect(pulse_row).to include(value: 1)
    end

    it "records a down transition immediately" do
      allow(DB).to receive(:get).and_raise(Sequel::DatabaseConnectionError)
      previous_pulse = {reading: "up", reading_rpt: 7, reading_chg: Time.now - 35}
      expect(postgres_server.check_pulse(session:, previous_pulse:)[:reading]).to eq("down")
      expect(pulse_row).to include(value: 0)
    end

    it "does not write between heartbeats" do
      previous_pulse = {reading: "up", reading_rpt: 5, reading_chg: Time.now - 25}
      postgres_server.check_pulse(session:, previous_pulse:)
      expect(pulse_row).to be_nil
    end

    it "writes a heartbeat on every sixth reading" do
      previous_pulse = {reading: "up", reading_rpt: 6, reading_chg: Time.now - 30}
      postgres_server.check_pulse(session:, previous_pulse:)
      expect(pulse_row).to include(value: 1)
    end

    it "does not write while the kill switch is off" do
      allow(Config).to receive(:postgres_cp_metrics_export_enabled).and_return(false)
      postgres_server.check_pulse(session:, previous_pulse: {})
      expect(pulse_row).to be_nil
    end

    it "returns the pulse and logs when the metric write fails" do
      POSTGRES_MONITOR_DB.rename_table(:postgres_int_metric_monitor, :postgres_int_metric_monitor_gone)
      expect(Clog).to receive(:emit).with("postgres cp metric write failed", hash_including(ubid: postgres_server.ubid)).and_call_original
      expect(postgres_server.check_pulse(session:, previous_pulse: {})[:reading]).to eq("up")
    ensure
      POSTGRES_MONITOR_DB.rename_table(:postgres_int_metric_monitor_gone, :postgres_int_metric_monitor)
    end
  end

  describe "#init_health_monitor_session" do
    def pulse_row
      POSTGRES_MONITOR_DB[:postgres_int_metric_monitor].where(postgres_server_id: postgres_server.id).first
    end

    after { POSTGRES_MONITOR_DB[:postgres_int_metric_monitor].delete }

    it "records a down reading and re-raises when the SSH session cannot be opened" do
      allow(Config).to receive(:postgres_cp_metrics_export_enabled).and_return(true)
      expect(postgres_server.vm.sshable).to receive(:start_fresh_session).and_raise(Errno::ECONNREFUSED)
      expect { postgres_server.init_health_monitor_session }.to raise_error(Errno::ECONNREFUSED)
      expect(pulse_row).to include(value: 0)
    end

    it "re-raises the SSH error, not the write error, when the metric write also fails" do
      allow(Config).to receive(:postgres_cp_metrics_export_enabled).and_return(true)
      expect(postgres_server.vm.sshable).to receive(:start_fresh_session).and_raise(Errno::ECONNREFUSED)
      POSTGRES_MONITOR_DB.rename_table(:postgres_int_metric_monitor, :postgres_int_metric_monitor_gone)
      expect(Clog).to receive(:emit).with("postgres cp metric write failed", anything).and_call_original
      expect { postgres_server.init_health_monitor_session }.to raise_error(Errno::ECONNREFUSED)
    ensure
      POSTGRES_MONITOR_DB.rename_table(:postgres_int_metric_monitor_gone, :postgres_int_metric_monitor)
    end

    it "does not write when the session opens" do
      allow(Config).to receive(:postgres_cp_metrics_export_enabled).and_return(true)
      ssh_session = Net::SSH::Connection::Session.allocate
      forward = instance_double(Net::SSH::Service::Forward)
      expect(forward).to receive(:local_socket)
      expect(ssh_session).to receive(:forward).and_return(forward)
      expect(postgres_server.vm.sshable).to receive(:start_fresh_session).and_return(ssh_session)
      expect(postgres_server.init_health_monitor_session[:ssh_session]).to eq(ssh_session)
      expect(pulse_row).to be_nil
    end
  end

  describe "#before_destroy" do
    after { POSTGRES_MONITOR_DB[:postgres_int_metric_monitor].delete }

    it "removes the server's pulse monitor row" do
      POSTGRES_MONITOR_DB[:postgres_int_metric_monitor].insert(postgres_server_id: postgres_server.id, metric_name: "pg_cp_up", value: 1, observed_at: Time.now)
      postgres_server.destroy
      expect(POSTGRES_MONITOR_DB[:postgres_int_metric_monitor].where(postgres_server_id: postgres_server.id).first).to be_nil
    end
  end
end
