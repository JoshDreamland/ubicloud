#!/usr/bin/env ruby
# frozen_string_literal: true

# :nocov:

# Detects instance families that become available in new regions in this PR by
# comparing config/instance_availability.yml against its base-branch version
# (BASE_AVAILABILITY_PATH). Instance *size* changes within a family are ignored;
# only the set of (region, family) pairs matters.
#
# Writes a Markdown report to NEW_AVAILABILITY_REPORT_PATH (an alert when new
# (region, family) pairs appear, or a resolved notice when none do) and records
# state=alert|clean|skip to GITHUB_OUTPUT. Always exits 0 (informational).

require "yaml"

def family_region_pairs(data)
  locations = data.dig("providers", "aws", "locations") || {}
  locations.flat_map { |region, info| (info["families"] || {}).keys.map { |family| [region, family] } }
end

def set_output(key, value)
  out = ENV["GITHUB_OUTPUT"]
  File.write(out, "#{key}=#{value}\n", mode: "a") if out
end

root = File.expand_path("..", __dir__)
current = YAML.load_file(File.join(root, "config/instance_availability.yml"))
report = ENV["NEW_AVAILABILITY_REPORT_PATH"]

base_path = ENV["BASE_AVAILABILITY_PATH"]
unless base_path && File.file?(base_path) && !File.empty?(base_path)
  puts "No base instance availability to compare against; skipping."
  set_output("state", "skip")
  exit 0
end

added = family_region_pairs(current) - family_region_pairs(YAML.load_file(base_path))

if added.empty?
  puts "No newly-available instance types in this PR."
  if report
    File.write(report, <<~MARKDOWN)
      <!-- new-instance-availability -->
      ## ✅ No new instance types in this PR

      This PR no longer introduces instance types in new regions.
    MARKDOWN
  end
  set_output("state", "clean")
  exit 0
end

by_region = added.group_by(&:first).transform_values { |pairs| pairs.map(&:last).sort }
warn "Newly available instance types:"
by_region.sort.each { |region, families| warn "  #{region}: #{families.join(", ")}" }

if report
  rows = by_region.sort.map { |region, families| "| #{region} | #{families.join(", ")} |" }.join("\n")
  File.write(report, <<~MARKDOWN)
    <!-- new-instance-availability -->
    ## 🆕🔴 New instance types available in regions 🔴🆕

    > [!IMPORTANT]
    > This PR makes the following instance types available in new regions (per `config/instance_availability.yml`):

    | Region | Instance types |
    | --- | --- |
    #{rows}

    ### 🚨🔴 **ACTION REQUIRED** 🔴🚨 — **Check in with Kaushik Iska, Kunal Gupta, Andrey Chudnovskiy and Kevin Biju** to provide billing details for these types to the Billing team.
  MARKDOWN
end

set_output("state", "alert")
exit 0
