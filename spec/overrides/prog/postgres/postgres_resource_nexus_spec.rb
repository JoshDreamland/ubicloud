# frozen_string_literal: true

require_relative "../../../prog/postgres/spec_helper"

RSpec.describe Prog::Postgres::PostgresResourceNexus::PrependMethods do # rubocop:disable RSpec/SpecFilePathFormat
  subject(:nx) { Prog::Postgres::PostgresResourceNexus.new(st) }

  let(:project) { Project.create(name: "test-project") }
  let(:postgres_resource) { create_postgres_resource(project:, location_id:) }
  let(:postgres_server) { create_postgres_server(resource: postgres_resource) }
  let(:st) { postgres_resource.strand }
  let(:postgres_project) { Project.create(name: "postgres-service-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }
  let(:billing_rate_id) { BillingRate.from_resource_properties("PostgresVCpu", "standard-standard", "hetzner-fsn1", false)["id"] }

  let(:override_method) { described_class.instance_method(:create_billing_record) }

  before do
    allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)
    project.set_ff_chc_postgres_deactivate_lockout(true)
  end

  describe "#create_billing_record" do
    it "populates billing record tags from resource tags and properties" do
      postgres_server
      postgres_resource.update(tags: Sequel.pg_jsonb([{"key" => "env", "value" => "prod"}]))

      override_method.bind_call(nx, billing_rate_id:, amount: 1, slot: "primary-vcpu")

      br = BillingRecord.where(resource_id: postgres_resource.id).first
      expect(br.resource_tags["env"]).to eq("prod")
      expect(br.resource_tags["cloud_provider"]).not_to be_nil
      expect(br.resource_tags["region"]).to eq(postgres_resource.location.name)
      expect(br.resource_tags["slot"]).to eq("primary-vcpu")
    end

    # The override is always prepended (OVERRIDE_DIR is set per test suite run, not individual test),
    # Therefore, need to call parent method explicitly to maintain coverage.
    # TODO: work with Ubicloud team to enable parent method tests to test parent method code,
    # even if override exists.
    it "overrides the base create_billing_record" do
      postgres_server
      base_method = nx.method(:create_billing_record).super_method
      expect(base_method).not_to be_nil
      base_method.call(billing_rate_id:, amount: 1, slot: "primary-vcpu")
      br = BillingRecord.where(resource_id: postgres_resource.id).first
      expect(br.resource_tags).to eq({"slot" => "primary-vcpu"})
    end
  end

  describe "#wait" do
    before { postgres_server }

    it "hops to billing_deactivate_suspend when billing_deactivate semaphore is set, before super's nap" do
      nx.incr_billing_deactivate
      expect { nx.wait }.to hop("billing_deactivate_suspend")
    end

    it "delegates to super when billing_deactivate semaphore is not set" do
      expect(nx.method(:wait).super_method).not_to be_nil
      # Sanity: super's wait naps at the end when no other hop fires.
      expect { nx.wait }.to nap(30)
    end

    it "runs mark_billing_deactivated when its semaphore is set, then delegates to super" do
      nx.incr_mark_billing_deactivated
      expect(nx).to receive(:mark_billing_deactivated).and_call_original
      allow(nx.postgres_resource).to receive_messages(servers: [], read_replicas: [], active_billing_records: [])
      expect { nx.wait }.to nap(30)
    end

    it "runs mark_billing_activated when its semaphore is set, then delegates to super" do
      postgres_resource.update(tags: Sequel.pg_jsonb([{"key" => "chc_state", "value" => "deactivated"}]))
      nx.incr_mark_billing_activated
      expect(nx).to receive(:mark_billing_activated).and_call_original
      allow(nx.postgres_resource).to receive_messages(servers: [], read_replicas: [])
      expect { nx.wait }.to nap(30)
    end

    it "prefers activate over deactivate when both semaphores are set (newer customer intent wins)" do
      postgres_resource.update(tags: Sequel.pg_jsonb([{"key" => "chc_state", "value" => "deactivated"}]))
      nx.incr_mark_billing_activated
      nx.incr_mark_billing_deactivated
      expect(nx).to receive(:mark_billing_activated).and_call_original
      expect(nx).not_to receive(:mark_billing_deactivated)
      allow(nx.postgres_resource).to receive_messages(servers: [], read_replicas: [])
      expect { nx.wait }.to nap(30)
    end
  end

  describe "#update_billing_records" do
    before { postgres_server }

    it "no-ops and hops to wait when the resource is deactivated (prevents billing reopen during pause)" do
      postgres_resource.update(tags: Sequel.pg_jsonb([{"key" => "chc_state", "value" => "deactivated"}]))
      nx.incr_update_billing_records
      st.update(label: "update_billing_records")
      expect(nx).not_to receive(:create_billing_record)
      expect { nx.update_billing_records }.to hop("wait")
    end

    it "drains initial_provisioning when deactivated (matches upstream's always-drain semantics)" do
      postgres_resource.update(tags: Sequel.pg_jsonb([{"key" => "chc_state", "value" => "deactivated"}]))
      nx.incr_update_billing_records
      nx.incr_initial_provisioning
      st.update(label: "update_billing_records")
      expect { nx.update_billing_records }.to hop("wait")
      expect(nx.initial_provisioning_set?).to be(false)
    end

    it "no-ops when mark_billing_deactivated is queued but the tag isn't yet written" do
      # Tag NOT written; only the semaphore is queued.
      nx.incr_update_billing_records
      nx.incr_mark_billing_deactivated
      st.update(label: "update_billing_records")
      expect(nx).not_to receive(:create_billing_record)
      expect { nx.update_billing_records }.to hop("wait")
    end

    it "delegates to super when the resource is not deactivated" do
      nx.incr_update_billing_records
      st.update(label: "update_billing_records")
      expect { nx.update_billing_records }.to hop("wait")
    end

    it "calls super unconditionally when chc_postgres_deactivate_lockout flag is OFF (even if deactivated)" do
      project.set_ff_chc_postgres_deactivate_lockout(false)
      postgres_resource.update(tags: Sequel.pg_jsonb([{"key" => "chc_state", "value" => "deactivated"}]))
      nx.incr_update_billing_records
      st.update(label: "update_billing_records")
      expect { nx.update_billing_records }.to hop("wait")
    end
  end

  describe "#mark_billing_deactivated" do
    before { postgres_server }

    it "writes chc_state BEFORE lockout (closes pg_hba race), then lockout/finalize/cascade, then chc_deactivated_at" do
      primary = instance_double(PostgresServer, is_representative: true).tap { allow(it).to receive(:apply_lockout) }
      standby = instance_double(PostgresServer, is_representative: false).tap { allow(it).to receive(:apply_lockout) }
      replica = instance_double(PostgresResource)
      br = instance_double(BillingRecord)
      allow(nx.postgres_resource).to receive_messages(servers: [primary, standby], active_billing_records: [br], read_replicas: [replica])

      expect(nx).to receive(:decr_mark_billing_deactivated)
      # Customer's late /activate during the deactivate handler must survive.
      expect(nx).not_to receive(:decr_mark_billing_activated)
      expect(br).to receive(:finalize)
      expect(nx.postgres_resource).to receive(:update).ordered.and_call_original # phase 1: chc_state
      expect(standby).to receive(:apply_lockout).ordered
      expect(primary).to receive(:apply_lockout).ordered
      expect(replica).to receive(:incr_mark_billing_deactivated)
      expect(nx.postgres_resource).to receive(:update).ordered.and_call_original # phase 3: chc_deactivated_at

      nx.mark_billing_deactivated
      tags = nx.postgres_resource.reload.tags
      expect(tags).to include({"key" => "chc_state", "value" => "deactivated"})
      expect(tags.find { it["key"] == "chc_deactivated_at" }["value"]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
    end

    it "re-runs phase 2 and writes chc_deactivated_at when only chc_state is present (crash-mid-handler retry)" do
      postgres_resource.update(tags: Sequel.pg_jsonb([{"key" => "chc_state", "value" => "deactivated"}]))
      server = instance_double(PostgresServer, is_representative: true).tap { allow(it).to receive(:apply_lockout) }
      allow(nx.postgres_resource).to receive_messages(servers: [server], active_billing_records: [], read_replicas: [])

      expect(server).to receive(:apply_lockout)
      nx.mark_billing_deactivated

      tags = nx.postgres_resource.reload.tags
      expect(tags.find { it["key"] == "chc_deactivated_at" }["value"]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
    end

    it "drains the semaphore and is otherwise a no-op when chc_state=deactivated tag is already set" do
      postgres_resource.update(tags: Sequel.pg_jsonb([{"key" => "env", "value" => "prod"}, {"key" => "chc_state", "value" => "deactivated"}, {"key" => "chc_deactivated_at", "value" => "2020-01-01T00:00:00Z"}]))
      allow(nx.postgres_resource).to receive_messages(servers: [], active_billing_records: [], read_replicas: [])

      expect(nx).to receive(:decr_mark_billing_deactivated)
      expect(nx).not_to receive(:decr_mark_billing_activated)
      nx.mark_billing_deactivated

      tags = nx.postgres_resource.reload.tags
      expect(tags.find { it["key"] == "chc_deactivated_at" }["value"]).to eq("2020-01-01T00:00:00Z")
      expect(tags).to include({"key" => "env", "value" => "prod"})
    end

    it "writes a single chc_state and chc_deactivated_at tag pair when none existed before" do
      postgres_resource.update(tags: Sequel.pg_jsonb([]))
      allow(nx.postgres_resource).to receive_messages(servers: [], active_billing_records: [], read_replicas: [])

      nx.mark_billing_deactivated

      tags = nx.postgres_resource.reload.tags
      expect(tags.map { it["key"] }.sort).to eq(["chc_deactivated_at", "chc_state"])
    end

    it "legacy path when flag OFF: writes chc_state only, skips lockout, skips chc_deactivated_at" do
      project.set_ff_chc_postgres_deactivate_lockout(false)
      postgres_resource.update(tags: Sequel.pg_jsonb([]))
      server = instance_double(PostgresServer, is_representative: true).tap { allow(it).to receive(:apply_lockout) }
      br = instance_double(BillingRecord)
      allow(nx.postgres_resource).to receive_messages(servers: [server], active_billing_records: [br], read_replicas: [])

      expect(server).not_to receive(:apply_lockout)
      expect(br).to receive(:finalize)
      expect(nx).to receive(:decr_mark_billing_deactivated)

      nx.mark_billing_deactivated

      tags = nx.postgres_resource.reload.tags
      expect(tags).to include({"key" => "chc_state", "value" => "deactivated"})
      expect(tags.map { it["key"] }).not_to include("chc_deactivated_at")
    end

    it "legacy path when flag OFF: retry-safe when tag already set — still finalizes, cascades, decrs" do
      project.set_ff_chc_postgres_deactivate_lockout(false)
      postgres_resource.update(tags: Sequel.pg_jsonb([{"key" => "chc_state", "value" => "deactivated"}]))
      br = instance_double(BillingRecord)
      replica = instance_double(PostgresResource)
      allow(nx.postgres_resource).to receive_messages(servers: [], active_billing_records: [br], read_replicas: [replica])

      expect(br).to receive(:finalize)
      expect(replica).to receive(:incr_mark_billing_deactivated)
      expect(nx).to receive(:decr_mark_billing_deactivated)
      # Tag already set — must NOT rewrite.
      expect(nx.postgres_resource).not_to receive(:update)
      nx.mark_billing_deactivated
    end
  end

  describe "#mark_billing_activated" do
    before do
      postgres_server
      postgres_resource.update(tags: Sequel.pg_jsonb([{"key" => "env", "value" => "prod"}, {"key" => "chc_state", "value" => "deactivated"}, {"key" => "chc_deactivated_at", "value" => "2026-06-20T00:00:00Z"}]))
    end

    it "clears chc_state and chc_deactivated_at (preserving others), reopens billing, configures each server, drains both billing-state semaphores, and does not cascade to replicas" do
      server = instance_double(PostgresServer)
      replica = instance_double(PostgresResource)
      allow(nx.postgres_resource).to receive_messages(servers: [server], read_replicas: [replica])

      expect(nx).to receive(:decr_mark_billing_activated)
      expect(nx).to receive(:decr_mark_billing_deactivated)
      expect(nx.postgres_resource).to receive(:incr_update_billing_records)
      expect(server).to receive(:incr_configure)
      expect(replica).not_to receive(:incr_mark_billing_activated)

      nx.mark_billing_activated

      tags = nx.postgres_resource.reload.tags
      expect(tags).to eq([{"key" => "env", "value" => "prod"}])
    end

    it "runs the activate steps idempotently when no chc_state tag is present (recovers from crashed deactivate that locked HBA but didn't tag)" do
      postgres_resource.update(tags: Sequel.pg_jsonb([{"key" => "env", "value" => "prod"}]))
      server = instance_double(PostgresServer)
      allow(nx.postgres_resource).to receive_messages(servers: [server], read_replicas: [])
      expect(nx).to receive(:decr_mark_billing_activated)
      expect(nx).to receive(:decr_mark_billing_deactivated)
      expect(nx.postgres_resource).to receive(:incr_update_billing_records)
      expect(server).to receive(:incr_configure)

      nx.mark_billing_activated

      expect(nx.postgres_resource.reload.tags).to eq([{"key" => "env", "value" => "prod"}])
    end
  end

  describe "#billing_deactivate_suspend" do
    before do
      postgres_server
      st.update(label: "billing_deactivate_suspend")
    end

    def mock_server(is_representative:)
      instance_double(PostgresServer, is_representative:).tap do |s|
        allow(s).to receive(:apply_lockout)
      end
    end

    it "registers a destroy deadline, locks out servers (standbys before primary), stamps kickoff time on the stack, triggers backup, and hops to billing_deactivate_wait_backup" do
      primary = mock_server(is_representative: true)
      standby = mock_server(is_representative: false)
      timeline = nx.postgres_resource.timeline
      allow(nx.postgres_resource).to receive_messages(servers: [primary, standby], timeline:)

      expect(timeline).to receive(:incr_take_backup_for_converge)
      expect(nx).to receive(:register_deadline).with("destroy", Prog::Postgres::PostgresResourceNexus::BILLING_DEACTIVATE_DEADLINE_SECONDS)
      expect(standby).to receive(:apply_lockout).ordered
      expect(primary).to receive(:apply_lockout).ordered

      expect { nx.billing_deactivate_suspend }.to hop("billing_deactivate_wait_backup")
      expect(st.stack.first["billing_deactivate_kicked_off_at"]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
    end

    it "naps 30 when timeline has no leader, without locking out servers or cascading to replicas (so retries don't pile up dead work)" do
      primary = mock_server(is_representative: true)
      replica = instance_double(PostgresResource)
      timeline = nx.postgres_resource.timeline
      allow(timeline).to receive(:leader).and_return(nil)
      allow(nx.postgres_resource).to receive_messages(timeline:)
      allow(nx.postgres_resource).to receive(:read_replicas).and_return([replica])

      expect(primary).not_to receive(:apply_lockout)
      expect(replica).not_to receive(:incr_billing_deactivate)
      expect(timeline).not_to receive(:incr_take_backup_for_converge)

      expect { nx.billing_deactivate_suspend }.to nap(30)
    end

    it "hops straight to destroy for resources that share the parent's timeline (read replica)" do
      shared_timeline = instance_double(PostgresTimeline, id: "shared-timeline-id")
      parent = instance_double(PostgresResource, timeline: shared_timeline)
      allow(nx.postgres_resource).to receive_messages(parent:, timeline: shared_timeline)
      expect(nx).to receive(:register_deadline).with("destroy", Prog::Postgres::PostgresResourceNexus::BILLING_DEACTIVATE_DEADLINE_SECONDS)
      expect(nx.postgres_resource).not_to receive(:servers)
      expect(shared_timeline).not_to receive(:incr_take_backup_for_converge)

      expect { nx.billing_deactivate_suspend }.to hop("destroy")
    end

    it "hops straight to destroy for mid-restore PITR resources that still point at the parent's timeline" do
      # PITR before switch_to_new_timeline: has parent + restore_target, but
      # timeline_id still == parent.timeline.id because the server is still in
      # fetch mode pulling from parent's bucket.
      shared_timeline = instance_double(PostgresTimeline, id: "shared-bucket-tl-id")
      parent = instance_double(PostgresResource, timeline: shared_timeline)
      allow(nx.postgres_resource).to receive_messages(parent:, timeline: shared_timeline)

      expect(shared_timeline).not_to receive(:incr_take_backup_for_converge)
      expect(nx.postgres_resource).not_to receive(:servers)
      expect { nx.billing_deactivate_suspend }.to hop("destroy")
    end

    it "does NOT short-circuit a post-restore PITR resource that has switched to its own timeline" do
      # After switch_to_new_timeline: same parent_id, but pg.timeline is a fresh
      # timeline distinct from parent.timeline — full deactivate flow is safe.
      primary = mock_server(is_representative: true)
      own_timeline = nx.postgres_resource.timeline
      parent_timeline = instance_double(PostgresTimeline, id: "parent-tl-id")
      parent = instance_double(PostgresResource, timeline: parent_timeline)
      allow(nx.postgres_resource).to receive_messages(parent:, servers: [primary], timeline: own_timeline)
      allow(own_timeline).to receive(:incr_take_backup_for_converge)

      expect { nx.billing_deactivate_suspend }.to hop("billing_deactivate_wait_backup")
    end

    it "decrements the billing_deactivate semaphore at entry so it is self-clearing" do
      primary = mock_server(is_representative: true)
      timeline = nx.postgres_resource.timeline
      allow(nx.postgres_resource).to receive_messages(servers: [primary], timeline:)
      allow(timeline).to receive(:incr_take_backup_for_converge)

      expect(nx).to receive(:decr_billing_deactivate)
      expect { nx.billing_deactivate_suspend }.to hop("billing_deactivate_wait_backup")
    end

    it "finalizes active billing records so charges stop the moment deactivate fires (before_run does not finalize on hop_destroy path)" do
      primary = mock_server(is_representative: true)
      timeline = nx.postgres_resource.timeline
      allow(nx.postgres_resource).to receive_messages(servers: [primary], timeline:)
      allow(timeline).to receive(:incr_take_backup_for_converge)
      br1 = instance_double(BillingRecord)
      br2 = instance_double(BillingRecord)
      allow(nx.postgres_resource).to receive(:active_billing_records).and_return([br1, br2])

      expect(br1).to receive(:finalize)
      expect(br2).to receive(:finalize)
      expect { nx.billing_deactivate_suspend }.to hop("billing_deactivate_wait_backup")
    end

    it "finalizes active billing records on the shared-parent-timeline short-circuit path too" do
      shared_timeline = instance_double(PostgresTimeline, id: "shared-timeline-id")
      parent = instance_double(PostgresResource, timeline: shared_timeline)
      allow(nx.postgres_resource).to receive_messages(parent:, timeline: shared_timeline)
      br = instance_double(BillingRecord)
      allow(nx.postgres_resource).to receive(:active_billing_records).and_return([br])

      expect(br).to receive(:finalize)
      expect { nx.billing_deactivate_suspend }.to hop("destroy")
    end

    it "cascades billing_deactivate to each read replica so they are not orphaned when the parent is destroyed" do
      primary = mock_server(is_representative: true)
      timeline = nx.postgres_resource.timeline
      allow(nx.postgres_resource).to receive_messages(servers: [primary], timeline:)
      allow(timeline).to receive(:incr_take_backup_for_converge)
      replica_a = instance_double(PostgresResource)
      replica_b = instance_double(PostgresResource)
      allow(nx.postgres_resource).to receive(:read_replicas).and_return([replica_a, replica_b])

      expect(replica_a).to receive(:incr_billing_deactivate)
      expect(replica_b).to receive(:incr_billing_deactivate)
      expect { nx.billing_deactivate_suspend }.to hop("billing_deactivate_wait_backup")
    end

    it "writes the kickoff timestamp under a STRING key so a same-lease hop into wait_backup can fetch it without KeyError" do
      primary = mock_server(is_representative: true)
      timeline = nx.postgres_resource.timeline
      allow(nx.postgres_resource).to receive_messages(servers: [primary], timeline:)
      allow(timeline).to receive(:incr_take_backup_for_converge)

      expect { nx.billing_deactivate_suspend }.to hop("billing_deactivate_wait_backup")
      # In-memory stack (no reload) must use a string key — wait_backup fetches via "billing_deactivate_kicked_off_at"
      expect(st.stack.first).to have_key("billing_deactivate_kicked_off_at")
      expect(st.stack.first).not_to have_key(:billing_deactivate_kicked_off_at)
    end
  end

  describe "#billing_deactivate_wait_backup" do
    let(:kicked_off_at) { Time.now.utc - 30 }

    before do
      postgres_server
      st.update(label: "billing_deactivate_wait_backup", stack: [{"billing_deactivate_kicked_off_at" => kicked_off_at.iso8601}])
    end

    it "naps when no completed backup exists yet" do
      timeline = nx.postgres_resource.timeline
      allow(timeline).to receive(:backups).and_return([])
      allow(nx.postgres_resource).to receive(:timeline).and_return(timeline)

      expect { nx.billing_deactivate_wait_backup }.to nap(60)
    end

    it "naps when the latest sentinel predates the billing-deactivate kickoff" do
      pre_kickoff = Struct.new(:last_modified).new(kicked_off_at - 60)
      timeline = nx.postgres_resource.timeline
      allow(timeline).to receive(:backups).and_return([pre_kickoff])
      allow(nx.postgres_resource).to receive(:timeline).and_return(timeline)

      expect { nx.billing_deactivate_wait_backup }.to nap(60)
    end

    it "extends bucket lifecycle and hops to destroy when a sentinel newer than kickoff exists" do
      post_kickoff = Struct.new(:last_modified).new(kicked_off_at + 5)
      timeline = nx.postgres_resource.timeline
      allow(timeline).to receive(:backups).and_return([post_kickoff])
      allow(nx.postgres_resource).to receive(:timeline).and_return(timeline)

      expect(timeline).to receive(:set_lifecycle_policy).with(expiration_days: Config.billing_deactivate_retention_days)
      expect { nx.billing_deactivate_wait_backup }.to hop("destroy")
    end

    it "uses a stubbed Config.billing_deactivate_retention_days for the lifecycle window" do
      post_kickoff = Struct.new(:last_modified).new(kicked_off_at + 5)
      timeline = nx.postgres_resource.timeline
      allow(timeline).to receive(:backups).and_return([post_kickoff])
      allow(nx.postgres_resource).to receive(:timeline).and_return(timeline)
      allow(Config).to receive(:billing_deactivate_retention_days).and_return(30)

      expect(timeline).to receive(:set_lifecycle_policy).with(expiration_days: 30)
      expect { nx.billing_deactivate_wait_backup }.to hop("destroy")
    end
  end
end
