#!/bin/bash
# Creates the default Ubicloud project with private_locations enabled
# and sets POSTGRES_SERVICE_PROJECT_ID in .env.rb.
#
# The project id is pinned to match hosted environments
# (ubid pj7ymg9w74vj2n4czhc534rg6z, see spec/setup/configs/setup_test*.yaml)
# Supports overriding
#
# Usage: register-pg-project.sh

set -e

DEV_PROJECT_ID="${DEV_PROJECT_ID:-3fa904f0-e4dc-86d2-a919-f8b0a326206f}"

echo "=== Creating default project and account ==="

RACK_ENV=development bundle exec ruby -r ./loader -e '
  $stdout.sync = true
  project_id = ARGV[0]
  unless project_id.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
    abort "ERROR: DEV_PROJECT_ID #{project_id.inspect} is not a uuid."
  end

  ubid = UBID.from_uuidish(project_id).to_s
  unless ubid.start_with?(UBID::TYPE_PROJECT)
    warn "ERROR: DEV_PROJECT_ID #{project_id} decodes to ubid #{ubid}, which is not a"
    warn "project (#{UBID::TYPE_PROJECT}) ubid. The type is encoded in the uuid itself, so it"
    warn "cannot be chosen by hand. Generate a usable one with:"
    warn "  bundle exec ruby -r ./loader -e \"puts Project.generate_uuid\""
    exit 1
  end

  email = "dev@ubicloud.local"
  account = Account.first(email: email)
  unless account
    account = Account.create(email: email, status_id: 2)
  end
  puts "Account \"#{account.email}\" (id: #{account.id}, ubid: #{account.ubid})"

  project = Project[project_id]

  if project.nil? && (other = account.projects_dataset.first(name: "default"))
    warn "ERROR: a project named \"default\" already exists with id #{other.id}, but this"
    warn "script now pins #{project_id}. Project names are not unique (see"
    warn "migrate/20230714_not_unique_project_name.rb), so creating a second \"default\""
    warn "would leave two indistinguishable projects behind. Pick one:"
    warn "  - keep the existing project, forfeiting a stable id across resets:"
    warn "      DEV_PROJECT_ID=#{other.id} .devcontainer/scripts/prepare-pg-ubicloud.sh"
    warn "  - adopt the pinned id by resetting the development database, then re-running"
    warn "    prepare-pg-ubicloud.sh to rebuild the project, location and AMI rows:"
    warn "      bin/dev-aws-sweep            # list AWS leftovers first"
    warn "      bundle exec rake \"setup_database[development,false]\""
    warn "      .devcontainer/scripts/prepare-pg-ubicloud.sh"
    exit 1
  end

  unless project
    project = account.create_project_with_default_policy("default", project_id: project_id)
  end
  project.set_ff_private_locations(true)
  project.set_ff_postgres_aws_use_different_azs_for_standbys(true)
  puts "Project \"#{project.name}\" (id: #{project.id}, ubid: #{project.ubid})"

  # Add POSTGRES_SERVICE_PROJECT_ID to .env.rb
  env_rb = ".env.rb"
  env_line = "ENV[\"POSTGRES_SERVICE_PROJECT_ID\"] = \"#{project.id}\""
  content = File.exist?(env_rb) ? File.read(env_rb) : ""
  if content.include?("POSTGRES_SERVICE_PROJECT_ID")
    content.gsub!(/^ENV\["POSTGRES_SERVICE_PROJECT_ID"\].*$/, env_line)
    File.write(env_rb, content)
  else
    File.open(env_rb, "a") { |f| f.puts env_line }
  end

  pat = ApiKey.first(owner_table: "accounts", owner_id: account.id, project_id: project.id, used_for: "api")
  unless pat
    pat = ApiKey.create_personal_access_token(account, project: project)
    pat.unrestrict_token_for_project(project.id)
  end

  puts "PAT token: pat-#{pat.ubid}-#{pat.key}"

  # Remove shared (non-project-specific) locations — this devcontainer is for
  # the Clickhouse environment which only uses the project-owned AWS location.
  # Also drop each location strand + semaphores, else the orphaned LocationNexus
  # strand crash-loops on a nil subject.
  shared = Location.where(project_id: nil).all
  if shared.any?
    shared.each do |loc|
      Semaphore.where(strand_id: loc.id).destroy
      Strand.where(id: loc.id).destroy
      loc.destroy
    end
    puts "Removed #{shared.count} shared location(s): #{shared.map(&:display_name).join(", ")}"
  end

' -- "$DEV_PROJECT_ID"
