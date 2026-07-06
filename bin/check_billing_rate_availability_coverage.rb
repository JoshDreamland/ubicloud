#!/usr/bin/env ruby
# frozen_string_literal: true

# :nocov:

# Checks that every AWS instance family present in instance availability has a
# VmVCpu billing rate for each region in the billing matrix. Families listed under
# the matrix's excludedFamilies are exempt. Exits non-zero on a gap and, when
# COVERAGE_REPORT_PATH is set, writes a Markdown report (used to comment on the PR)
# listing the missing instance types per region.

require "yaml"

root = File.expand_path("..", __dir__)
matrix = YAML.load_file(File.join(root, "config/billing_rates_generator.yml"), permitted_classes: [Time])
availability = YAML.load_file(File.join(root, "config/instance_availability.yml"))
override = YAML.load_file(File.join(root, "config/billing_rates/overrides/vm_aws.yml"), permitted_classes: [Time])

aws = matrix.fetch("aws").fetch("billingRatesGenerator")
matrix_regions = aws.fetch("regions")
excluded = aws.fetch("excludedFamilies", [])
locations = availability.fetch("providers").fetch("aws").fetch("locations")

priced = Hash.new { |h, k| h[k] = [] }
override.each { |rate| priced[rate["location"]] << rate["resource_family"] if rate["resource_type"] == "VmVCpu" }

missing = matrix_regions.sort.each_with_object({}) do |region, acc|
  available = locations[region]&.fetch("families", {})&.keys
  next unless available
  gap = available - priced[region] - excluded
  acc[region] = gap.sort unless gap.empty?
end

if missing.empty?
  if (path = ENV["COVERAGE_REPORT_PATH"])
    File.write(path, <<~MARKDOWN)
      <!-- billing-rate-availability-coverage -->
      ## ✅ Billing rates cover all available instance types

      Every AWS instance family in `config/instance_availability.yml` now has a billing rate for each region in the matrix. Any previously-reported gaps are **resolved**.
    MARKDOWN
  end
  puts "OK: every available AWS instance family has a billing rate in each matrix region."
  exit 0
end

warn "Missing billing records for available instance types:"
missing.each { |region, families| warn "  #{region}: #{families.join(", ")}" }

if (path = ENV["COVERAGE_REPORT_PATH"])
  rows = missing.map { |region, families| "| #{region} | #{families.join(", ")} |" }.join("\n")
  File.write(path, <<~MARKDOWN)
    <!-- billing-rate-availability-coverage -->
    ## 🔴🔴 Missing billing rates for available instance types 🔴🔴

    > [!CAUTION]
    > The following instance types are available (per `config/instance_availability.yml`) in these regions but have **no billing rate** in `config/billing_rates/overrides/vm_aws.yml`:

    | Region | Instance types |
    | --- | --- |
    #{rows}

    ### 🚨🔴 **ACTION REQUIRED** 🔴🚨 — **Check in with Kaushik Iska, Kunal Gupta, Andrey Chudnovskiy and Kevin Biju** to provide billing details for these types to the Billing team.
  MARKDOWN
end

exit 1
