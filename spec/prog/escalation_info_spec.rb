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
      service_ubid: "pgrsc123"
    )
    expect(info.urgency).to eq("PAGE")
    expect(info.service_ubid).to eq("pgrsc123")
  end

  it "allows nil service_ubid" do
    info = described_class.new(
      urgency: "NOTIFY",
      owner: "ubicloud",
      blast_radius: "NONE",
      impact_timeline: "UNLIKELY",
      customer_impact: "NONE"
    )
    expect(info.service_ubid).to be_nil
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

  it "serializes to a hash without nil service_ubid" do
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
    expect(h).not_to have_key("service_ubid")
  end

  it "includes service_ubid in hash when present" do
    info = described_class.new(
      urgency: "PAGE",
      owner: "ubicloud",
      blast_radius: "SINGLE",
      impact_timeline: "NOW",
      customer_impact: "OUTAGE",
      service_ubid: "pgrsc456"
    )
    expect(info.to_h["service_ubid"]).to eq("pgrsc456")
  end
end
