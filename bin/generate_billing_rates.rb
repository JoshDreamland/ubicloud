#!/usr/bin/env ruby
# frozen_string_literal: true

# :nocov:

# Generates config/billing_rates/overrides/{vm,postgres}_<provider>.yml from the
# provider-keyed matrix in config/billing_rates_generator.yml. Each override file is
# the matching base file copied verbatim plus generated price-0 rows for every matrix
# combination not already present. Existing rates take precedence; ids are reused from
# the existing override on re-run, so output is stable (see the design doc under
# docs/superpowers/specs/). Override files are copied over the base files in the Dockerfile.
#
# Usage: ruby bin/generate_billing_rates.rb [matrix_file]

require "fileutils"
require "yaml"
require_relative "../lib/billing_rate_generator"

root = File.expand_path("..", __dir__)
matrix_file = ARGV[0] || File.join(root, "config/billing_rates_generator.yml")
base_dir = File.join(root, "config/billing_rates")
override_dir = File.join(base_dir, "overrides")
FileUtils.mkdir_p(override_dir)

kinds = %i[vm postgres]
matrix = YAML.load_file(matrix_file, permitted_classes: [Time])
matrix.each do |provider, provider_config|
  config = provider_config.fetch("billingRatesGenerator")
  kinds.each do |kind|
    name = "#{kind}_#{provider}.yml"
    base_path = File.join(base_dir, name)
    override_path = File.join(override_dir, name)
    base_text = File.file?(base_path) ? File.read(base_path) : ""
    override_text = File.file?(override_path) ? File.read(override_path) : nil

    output = BillingRateGenerator.new(kind:, config:, base_text:, override_text:).generate
    File.write(override_path, output)
    generated = output.lines.count { it.start_with?("- {") }
    puts "Wrote #{override_path.delete_prefix("#{root}/")} (#{generated} records)"
  end
end
