# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe "PageNexus enrichment" do
  describe "enricher registry" do
    it "has registered enrichers for Postgres types" do
      expect(Prog::PageNexus.enrichers).to have_key("PostgresServer")
      expect(Prog::PageNexus.enrichers).to have_key("PostgresResource")
      expect(Prog::PageNexus.enrichers).to have_key("PostgresTimeline")
    end
  end

  describe "run_enrichment" do
    let(:page) do
      instance_double(Page,
        summary: "test page summary",
        details: {"enrich" => {"subject_type" => "PostgresServer", "subject_id" => "fake-id"}},
        tag: "test-tag",
        "summary=": nil,
        save_changes: nil)
    end

    let(:nx) do
      strand = instance_double(Strand, id: "test-strand-id", stack: [{}], label: "start")
      allow(strand).to receive(:prog).and_return("PageNexus")
      Prog::PageNexus.new(strand)
    end

    it "does not raise when enricher returns nil" do
      Prog::PageNexus.register_enricher("TestNilEnricher") { |_page, _spec| nil }
      spec = {"subject_type" => "TestNilEnricher", "subject_id" => "x"}
      expect { nx.send(:run_enrichment, spec) }.not_to raise_error
    ensure
      Prog::PageNexus.enrichers.delete("TestNilEnricher")
    end

    it "does not raise when no enricher is registered" do
      spec = {"subject_type" => "UnknownType", "subject_id" => "x"}
      expect { nx.send(:run_enrichment, spec) }.not_to raise_error
    end

    it "does not raise when enricher raises" do
      Prog::PageNexus.register_enricher("TestErrorEnricher") { |_page, _spec| raise "boom" }
      spec = {"subject_type" => "TestErrorEnricher", "subject_id" => "x"}
      expect { nx.send(:run_enrichment, spec) }.not_to raise_error
    ensure
      Prog::PageNexus.enrichers.delete("TestErrorEnricher")
    end
  end
end
