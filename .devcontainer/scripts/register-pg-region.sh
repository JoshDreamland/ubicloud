#!/bin/bash
# Registers a single AWS region for PostgreSQL development in the Ubicloud
# database: creates a private location with credentials, fetches the latest
# AMI IDs from the CI pipeline, and updates the AMI rows in the DB.
#
# Usage: register-pg-region.sh REGION ASSUME_ROLE
#   REGION:      AWS region to register (e.g. us-west-2)
#   ASSUME_ROLE: ARN of the IAM role to assume for AWS access

set -e

REPO="ClickHouse/postgres-vm-images"

# Exit status used when the GitHub API itself is unreachable (bad credentials,
# exhausted quota, network). Callers can treat it as "AMIs not refreshed" and
# keep going, unlike a genuine failure such as an AMI missing from the logs.
GH_UNAVAILABLE=78

# Calls gh api and prints the response to stdout only when the request
# succeeded. On a non-2xx response gh writes the raw JSON error body to stdout
# (CRLF line endings) as well as a message to stderr, so the body must not be
# mistaken for a result: piping gh straight into head or grep discards its exit
# status and lets "{" become the value.
gh_api() {
  local path="$1"
  local body
  if ! body=$(gh api "$path" "${@:2}"); then
    echo "Error: gh api ${path} failed" >&2
    return "$GH_UNAVAILABLE"
  fi
  printf '%s\n' "$body"
}

# Fetch the latest AMI ID from the CI pipeline.
# Prints only the AMI ID to stdout; all informational messages go to stderr.
fetch_ami() {
  local region="$1"
  local arch="$2"

  # Fetch the latest successful build run for the PostgreSQL VM Image workflow
  local runs run_id
  runs=$(gh_api "repos/${REPO}/actions/runs?branch=main&status=success&per_page=20" \
    --jq '.workflow_runs[] | select(.name == "Build PostgreSQL VM Image") | .id') || return $?
  run_id=$(printf '%s\n' "$runs" | head -1)

  if ! [[ "$run_id" =~ ^[0-9]+$ ]]; then
    echo "Error: No successful build run found" >&2
    return 1
  fi

  # Fetch the latest job for the architecture
  local jobs job_id
  jobs=$(gh_api "repos/${REPO}/actions/runs/${run_id}/jobs?per_page=50" \
    --jq ".jobs[] | select(.name | test(\"${arch}\")) | .id") || return $?
  job_id=$(printf '%s\n' "$jobs" | head -1)

  if ! [[ "$job_id" =~ ^[0-9]+$ ]]; then
    echo "Error: No job found for arch ${arch} in run ${run_id}" >&2
    return 1
  fi

  # Fetch the AMI ID from the job logs
  local logs ami_id
  logs=$(gh_api "repos/${REPO}/actions/jobs/${job_id}/logs") || return $?
  ami_id=$(printf '%s\n' "$logs" \
    | grep -oP "Copied AMI to ${region}: \Kami-[0-9a-f]+" | head -1)

  if [ -z "$ami_id" ]; then
    echo "Error: No AMI found for region ${region} in logs of job ${job_id}" >&2
    return 1
  fi

  echo "AMI: ${ami_id} (region: ${region}, arch: ${arch}, run: ${run_id})" >&2
  echo "$ami_id"
}

REGION="${1:?Usage: $0 REGION ASSUME_ROLE}"
ASSUME_ROLE="${2:?Usage: $0 REGION ASSUME_ROLE}"

echo "=== Registering region ${REGION} ==="

# Create private location in Ubicloud DB
echo ""
echo "--- Creating private location ---"

RACK_ENV=development bundle exec ruby -r ./loader -e '
  region = ARGV[0]
  assume_role = ARGV[1]
  project = Project.first(name: "default")

  display_name = "#{region}-cell-0"
  loc = Location.first(project_id: project.id, display_name: display_name)
  if loc
    puts "Location \"#{display_name}\" already exists (id: #{loc.id})"
  else
    loc = Location.create(
      name: region,
      display_name: display_name,
      ui_name: display_name,
      visible: true,
      provider: "aws",
      project_id: project.id
    )
    LocationCredentialAws.create(access_key: "dummy", secret_key: "dummy") { it.id = loc.id }
    puts "Created location \"#{display_name}\" (id: #{loc.id})"
  end

  loc.location_credential_aws.update(access_key: nil, secret_key: nil, assume_role: assume_role)
  puts "Updated credential with assume_role: #{assume_role}"
' -- "$REGION" "$ASSUME_ROLE"

# Fetch latest AMIs from CI pipeline
echo ""
echo "--- Fetching latest PostgreSQL AMIs ---"

AMI_X64=$(fetch_ami "$REGION" x64)
AMI_ARM64=$(fetch_ami "$REGION" arm64)

echo ""
echo "x64:   ${AMI_X64}"
echo "arm64: ${AMI_ARM64}"

# Update AMI rows in the database
echo ""
echo "--- Updating AMIs in database ---"

RACK_ENV=development bundle exec ruby -r ./loader -e '
  region = ARGV[0]
  ami_x64 = ARGV[1]
  ami_arm64 = ARGV[2]

  updated_x64 = PgAwsAmi.where(aws_location_name: region, arch: "x64").update(aws_ami_id: ami_x64)
  updated_arm64 = PgAwsAmi.where(aws_location_name: region, arch: "arm64").update(aws_ami_id: ami_arm64)

  puts "Updated x64:   #{updated_x64} row(s) -> #{ami_x64}"
  puts "Updated arm64: #{updated_arm64} row(s) -> #{ami_arm64}"
' -- "$REGION" "$AMI_X64" "$AMI_ARM64"
