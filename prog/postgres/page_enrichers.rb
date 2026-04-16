# frozen_string_literal: true

# Enrichers for Postgres-related pages. These run in the PageNexus strand
# between page creation and trigger (the PagerDuty/incident.io handoff),
# rewriting the summary and adding context to details.
#
# Each enricher receives (page, spec) where spec is the Hash stored in
# details["enrich"] at assemble time. It should return a Hash with optional
# :summary and :details keys, or nil to skip enrichment.

Prog::PageNexus.register_enricher("PostgresServer") do |page, spec|
  server = PostgresServer[spec["subject_id"]]
  next unless server

  resource = server.resource
  strand = server.strand

  enriched_details = {
    "server_role" => server.primary? ? "primary" : "standby",
    "server_version" => server.version,
    "resource_name" => resource&.name,
    "resource_ubid" => resource&.ubid,
    "location" => resource&.location&.display_name,
    "strand_label" => strand&.label,
    "strand_try" => strand&.try,
  }

  last_label_changed = strand&.stack&.first&.[]("last_label_changed_at")
  if last_label_changed
    stuck_seconds = (Time.now - Time.parse(last_label_changed)).round
    enriched_details["stuck_in_label_seconds"] = stuck_seconds
  end

  enriched_summary = page.summary
  if resource
    role = server.primary? ? "primary" : "standby"
    enriched_summary = "[#{resource.name} #{role} @ #{resource.location.display_name}] #{page.summary}"
  end

  {summary: enriched_summary, details: enriched_details}
end

Prog::PageNexus.register_enricher("PostgresResource") do |page, spec|
  resource = PostgresResource[spec["subject_id"]]
  next unless resource

  rep = resource.representative_server
  enriched_details = {
    "resource_name" => resource.name,
    "resource_ubid" => resource.ubid,
    "location" => resource.location.display_name,
    "vm_size" => resource.vm_size,
    "version" => resource.version,
    "target_version" => resource.target_version,
    "server_count" => resource.servers.count,
    "representative_label" => rep&.strand&.label,
  }

  enriched_summary = "[#{resource.name} @ #{resource.location.display_name}] #{page.summary}"

  {summary: enriched_summary, details: enriched_details}
end

Prog::PageNexus.register_enricher("PostgresTimeline") do |page, spec|
  timeline = PostgresTimeline[spec["subject_id"]]
  next unless timeline

  leader = timeline.leader
  resource = leader&.resource
  enriched_details = {
    "timeline_ubid" => timeline.ubid,
    "leader_ubid" => leader&.ubid,
    "resource_name" => resource&.name,
    "resource_ubid" => resource&.ubid,
    "location" => resource&.location&.display_name,
    "latest_backup_started_at" => timeline.latest_backup_started_at&.to_s,
  }

  enriched_summary = if resource
    "[#{resource.name} @ #{resource.location.display_name}] #{page.summary}"
  else
    page.summary
  end

  {summary: enriched_summary, details: enriched_details}
end
