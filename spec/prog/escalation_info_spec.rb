# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::PageNexus::EscalationInfo do
  it "accepts valid values" do
    info = described_class.new(
      urgency: "PAGE",
      owner: "ubicloud",
      blast_radius: "SINGLE",
      impact_timeline: "SOON",
      customer_impact: "DEGRADE",
    )
    expect(info.urgency).to eq("PAGE")
  end

  it "defaults optional fields" do
    info = described_class.new(
      urgency: "NOTIFY",
      owner: "ubicloud",
      blast_radius: "NONE",
      impact_timeline: "UNLIKELY",
      customer_impact: "NONE"
    )
    expect(info.customer_actionable).to be false
    expect(info.oncall_mitigable).to be false
  end

  it "accepts routing overrides" do
    info = described_class.new(
      urgency: "PAGE",
      owner: "ubicloud",
      blast_radius: "SINGLE",
      impact_timeline: "SOON",
      customer_impact: "OUTAGE",
      customer_actionable: true,
      oncall_mitigable: true
    )
    expect(info.customer_actionable).to be true
    expect(info.oncall_mitigable).to be true
  end

  it "rejects invalid urgency" do
    expect {
      described_class.new(urgency: "CRITICAL", owner: "x", blast_radius: "NONE", impact_timeline: "SOON", customer_impact: "NONE")
    }.to raise_error(ArgumentError, /invalid urgency/)
  end

  it "rejects invalid blast_radius" do
    expect {
      described_class.new(urgency: "PAGE", owner: "x", blast_radius: "SOME", impact_timeline: "SOON", customer_impact: "NONE")
    }.to raise_error(ArgumentError, /invalid blast_radius/)
  end

  it "rejects invalid impact_timeline" do
    expect {
      described_class.new(urgency: "PAGE", owner: "x", blast_radius: "NONE", impact_timeline: "LATER", customer_impact: "NONE")
    }.to raise_error(ArgumentError, /invalid impact_timeline/)
  end

  it "rejects invalid customer_impact" do
    expect {
      described_class.new(urgency: "PAGE", owner: "x", blast_radius: "NONE", impact_timeline: "SOON", customer_impact: "BROKEN")
    }.to raise_error(ArgumentError, /invalid customer_impact/)
  end

  it "serializes to a hash, omitting nil fields" do
    info = described_class.new(
      urgency: "TICKET",
      owner: "ubicloud",
      blast_radius: "MANY",
      impact_timeline: "EVENTUALLY",
      customer_impact: "VISIBILITY"
    )
    h = info.to_h
    expect(h).to eq({
      "urgency" => "TICKET",
      "owner" => "ubicloud",
      "blast_radius" => "MANY",
      "impact_timeline" => "EVENTUALLY",
      "customer_impact" => "VISIBILITY"
    })
    expect(h["customer_actionable"]).to be false
    expect(h["oncall_mitigable"]).to be false
  end

  it "includes routing booleans in hash when true" do
    info = described_class.new(
      urgency: "PAGE",
      owner: "ubicloud",
      blast_radius: "SINGLE",
      impact_timeline: "SOON",
      customer_impact: "OUTAGE",
      customer_actionable: true,
      oncall_mitigable: true
    )
    h = info.to_h
    expect(h["customer_actionable"]).to be true
    expect(h["oncall_mitigable"]).to be true
  end

end
