# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::PostgresCpMetricsExport do
  subject(:nx) {
    described_class.new(Strand.create_with_id("ffffffff-ff00-833a-87c0-cb01ddb031a0", prog: "PostgresCpMetricsExport", label: "wait"))
  }

  describe "#wait" do
    # The expectation goes on SINGLETON rather than on PostgresCpMetricsExporter
    # itself: clover_freeze freezes the autoloaded class objects, and rspec-mocks
    # cannot proxy a frozen class, so stubbing the class method fails under
    # `rake frozen_spec`. The exporter keeps its state on that eagerly-created
    # instance for the same reason, and .export just delegates to it.
    it "naps a minute without exporting while the kill switch is off" do
      expect(PostgresCpMetricsExporter::SINGLETON).not_to receive(:export)
      expect { nx.wait }.to nap(60)
    end

    it "exports the full table state and naps the export interval when enabled" do
      allow(Config).to receive(:postgres_cp_metrics_export_enabled).and_return(true)
      expect(PostgresCpMetricsExporter::SINGLETON).to receive(:export)
      expect { nx.wait }.to nap(30)
    end
  end
end
