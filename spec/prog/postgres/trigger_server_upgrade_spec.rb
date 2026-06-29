# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Prog::Postgres::TriggerServerUpgrade do
  let(:project) { Project.create(name: "trigger-upgrade-test") }
  let(:location_id) { Location::HETZNER_FSN1_ID }
  let(:timeline) { create_postgres_timeline(location_id:) }
  let(:pg) { create_postgres_resource(project:, location_id:) }

  def create_server(is_representative:, label: "wait")
    s = create_postgres_server(resource: pg, timeline:, is_representative:)
    s.strand.update(label:)
    s
  end

  def nx_for(servers, semaphores: ["install_rhizome"])
    strand = Strand.create(
      prog: "Postgres::TriggerServerUpgrade", label: "start", parent_id: pg.strand.id,
      stack: [{"subject_id" => pg.id, "server_ids" => servers.map(&:id), "semaphores" => semaphores}],
    )
    described_class.new(strand)
  end

  def sem_count(server, name = "install_rhizome")
    DB[:semaphore].where(strand_id: server.id, name:).count
  end

  describe "#start" do
    it "triggers targeted standbys only, then hops to wait_standbys" do
      primary = create_server(is_representative: true)
      standby = create_server(is_representative: false)

      expect { nx_for([primary, standby]).start }.to hop("wait_standbys")
      expect(sem_count(standby)).to eq(1)
      expect(sem_count(primary)).to eq(0)
    end
  end

  describe "#wait_standbys" do
    it "naps while a targeted standby has not converged" do
      primary = create_server(is_representative: true)
      standby = create_server(is_representative: false)
      Semaphore.incr(standby.id, "install_rhizome")

      expect { nx_for([primary, standby]).wait_standbys }.to nap(5)
    end

    it "triggers the primary and hops once standbys converged" do
      primary = create_server(is_representative: true)
      standby = create_server(is_representative: false)

      expect { nx_for([primary, standby]).wait_standbys }.to hop("wait_primary")
      expect(sem_count(primary)).to eq(1)
    end

    it "does not trigger the primary when it is not targeted" do
      primary = create_server(is_representative: true)
      standby = create_server(is_representative: false)

      expect { nx_for([standby]).wait_standbys }.to hop("wait_primary")
      expect(sem_count(primary)).to eq(0)
    end
  end

  describe "#wait_primary" do
    it "naps while the targeted primary has not converged" do
      primary = create_server(is_representative: true)
      Semaphore.incr(primary.id, "install_rhizome")

      expect { nx_for([primary]).wait_primary }.to nap(5)
    end

    it "pops once the primary converged" do
      primary = create_server(is_representative: true)

      expect { nx_for([primary]).wait_primary }.to exit({"msg" => "triggered install_rhizome standby-first on 1 server(s)"})
    end

    it "pops without waiting when the primary is not targeted" do
      create_server(is_representative: true)
      standby = create_server(is_representative: false)

      expect { nx_for([standby]).wait_primary }.to exit({"msg" => "triggered install_rhizome standby-first on 1 server(s)"})
    end
  end

  describe "#converged?" do
    it "treats a server whose strand has gone away as converged" do
      server = create_server(is_representative: true)
      nx = nx_for([server])
      server.strand.destroy

      expect(nx.converged?(server.reload)).to be(true)
    end
  end
end
