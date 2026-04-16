# frozen_string_literal: true

class Prog::PageNexus < Prog::Base
  subject_is :page

  VALID_URGENCIES = %w[PAGE TICKET NOTIFY].freeze
  VALID_BLAST_RADII = %w[NONE SINGLE MANY ALL].freeze
  VALID_IMPACT_TIMELINES = %w[UNLIKELY EVENTUALLY SOON NOW].freeze
  VALID_CUSTOMER_IMPACTS = %w[NONE VISIBILITY DEGRADE OUTAGE].freeze

  EscalationInfo = Data.define(:urgency, :owner, :blast_radius, :impact_timeline, :customer_impact, :service_ubid) do
    def initialize(urgency:, owner:, blast_radius:, impact_timeline:, customer_impact:, service_ubid: nil)
      raise ArgumentError, "invalid urgency: #{urgency}" unless Prog::PageNexus::VALID_URGENCIES.include?(urgency)
      raise ArgumentError, "invalid blast_radius: #{blast_radius}" unless Prog::PageNexus::VALID_BLAST_RADII.include?(blast_radius)
      raise ArgumentError, "invalid impact_timeline: #{impact_timeline}" unless Prog::PageNexus::VALID_IMPACT_TIMELINES.include?(impact_timeline)
      raise ArgumentError, "invalid customer_impact: #{customer_impact}" unless Prog::PageNexus::VALID_CUSTOMER_IMPACTS.include?(customer_impact)
      super
    end

    def to_h
      {
        "urgency" => urgency,
        "owner" => owner,
        "blast_radius" => blast_radius,
        "impact_timeline" => impact_timeline,
        "customer_impact" => customer_impact,
        "service_ubid" => service_ubid
      }.compact
    end
  end

  def self.assemble(summary, tag_parts, related_resources, severity: "error", extra_data: {}, escalation: nil)
    DB.transaction do
      details = extra_data.merge({"related_resources" => Array(related_resources)})
      details["escalation"] = escalation.to_h if escalation
      tag = Page.generate_tag(tag_parts)

      if (existing_page = Page.first(tag:)) && Page.severity_order(severity) > Page.severity_order(existing_page.severity)
        existing_page.incr_retrigger
      end

      page = Page.new(summary:, details:, tag:, severity:)
      page.skip_auto_validations(:unique) do
        page.insert_conflict(
          target: :tag,
          conflict_where: {resolved_at: nil},
          update: {summary: Sequel[:excluded][:summary], details: Sequel[:excluded][:details], severity: Sequel[:excluded][:severity]},
        ).save_changes
      end

      Strand.new(prog: "PageNexus", label: "start") { it.id = page.id }
        .insert_conflict(target: :id).save_changes
    end
  end

  label def start
    page.trigger
    hop_wait
  end

  label def wait
    when_retrigger_set? do
      page.trigger
      decr_retrigger
    end

    when_resolve_set? do
      page.resolve
      page.destroy
      pop "page is resolved"
    end

    nap 6 * 60 * 60
  end
end
