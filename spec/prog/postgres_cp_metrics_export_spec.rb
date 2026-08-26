# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::PostgresCpMetricsExport do
  subject(:nx) {
    described_class.new(Strand.create_with_id("ffffffff-ff00-833a-87c0-cb01ddb031a0", prog: "PostgresCpMetricsExport", label: "wait"))
  }

  describe "#wait" do
    it "naps a minute without exporting while the kill switch is off" do
      expect(PostgresCpMetricsExporter).not_to receive(:export)
      expect { nx.wait }.to nap(60)
    end

    it "exports the full table state and naps the export interval when enabled" do
      allow(Config).to receive(:postgres_cp_metrics_export_enabled).and_return(true)
      expect(PostgresCpMetricsExporter).to receive(:export)
      expect { nx.wait }.to nap(30)
    end
  end
end
