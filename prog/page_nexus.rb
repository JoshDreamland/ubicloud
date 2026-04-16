# frozen_string_literal: true

class Prog::PageNexus < Prog::Base
  subject_is :page

  # Registry of enricher callables. Each key is a subject_type string,
  # each value is a callable that accepts (page, enrichment_spec) and
  # returns {summary: String, details: Hash} or nil.
  @enrichers = {}

  def self.enrichers
    @enrichers
  end

  def self.register_enricher(subject_type, &block)
    @enrichers[subject_type] = block
  end

  # Load enrichers. These register themselves via register_enricher.
  # Loaded once at class definition time.
  Dir[File.join(__dir__, "**", "page_enrichers.rb")].each { require it }

  def self.assemble(summary, tag_parts, related_resources, severity: "error", extra_data: {}, enrich: nil)
    DB.transaction do
      details = extra_data.merge({"related_resources" => Array(related_resources)})
      if enrich
        details["enrich"] = enrich.merge("fired_at" => Time.now.to_s)
      end
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
    if (spec = page.details["enrich"])
      run_enrichment(spec)
    end
    # Log the full page payload to structured logging so it survives
    # page table cleanup regardless of retention window.
    Clog.emit("page fired", {page_fired: {tag: page.tag, summary: page.summary, severity: page.severity, details: page.details}})
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

  private def run_enrichment(spec)
    subject_type = spec["subject_type"]
    enricher = self.class.enrichers[subject_type]
    unless enricher
      Clog.emit("no enricher registered", {page_enrichment: {tag: page.tag, subject_type:}})
      return
    end

    result = enricher.call(page, spec)
    return unless result

    if result[:summary]
      page.summary = result[:summary]
    end
    if result[:details]
      page.details.merge!(result[:details])
    end
    page.save_changes
  rescue => ex
    # Enrichment failure must never prevent the page from firing.
    Clog.emit("page enrichment failed", Util.exception_to_hash(ex, into: {page_enrichment: {tag: page.tag, subject_type:}}))
  end
end
