#!/bin/bash
# Registers a single GCP region for PostgreSQL development: creates a
# project-owned location with impersonation credentials, enables the GCP
# instance families, and points pg_gce_image at the images
# ClickHouse/postgres-vm-images builds. GCP twin of register-pg-region.sh.
# Image names come from the postgres-vm-images build logs if not provided
#
# Usage: register-pg-gcp-region.sh REGION [--image-x64 NAME] [--image-arm64 NAME]
#   REGION: bare GCP region, e.g. us-central1 (the location is named gcp-REGION)

set -e

REPO="ClickHouse/postgres-vm-images"
IMAGE_PROJECT="${POSTGRES_GCE_IMAGE_GCP_PROJECT_ID:-dataplane-deployment}"
PG_VERSIONS="16,17,18"

# Same convention as register-pg-region.sh: the AMI/image refresh needs GitHub,
# and an unreachable API is reported separately from a genuine failure so
# prepare-pg-ubicloud.sh can carry on with the location already created.
GH_UNAVAILABLE=78

REGION="${1:?Usage: $0 REGION [--image-x64 NAME] [--image-arm64 NAME]}"
shift

IMAGE_X64=""
IMAGE_ARM64=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --image-x64) IMAGE_X64="$2"; shift 2 ;;
    --image-arm64) IMAGE_ARM64="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

: "${GCP_PROJECT_ID:?GCP_PROJECT_ID is not set. Ensure it is defined in docker-compose.yml or exported in your shell.}"
: "${GCP_CELL_SERVICE_ACCOUNT:?GCP_CELL_SERVICE_ACCOUNT is not set. Ensure it is defined in docker-compose.yml or exported in your shell.}"

echo "=== Registering GCP region ${REGION} ==="

# Prints the newest GCE image name for an arch, from the build logs. The build
# emits "Creating GCE image: <name>" once per arch job.
fetch_gce_image() {
  local arch="$1" runs run_id jobs job_id logs image

  runs=$(gh api "repos/${REPO}/actions/runs?branch=main&status=success&per_page=20" \
    --jq '.workflow_runs[] | select(.name == "Build PostgreSQL VM Image") | .id') || return "$GH_UNAVAILABLE"
  run_id=$(printf '%s\n' "$runs" | head -1)
  if ! [[ "$run_id" =~ ^[0-9]+$ ]]; then
    echo "Error: no successful build run found" >&2
    return 1
  fi

  jobs=$(gh api "repos/${REPO}/actions/runs/${run_id}/jobs?per_page=50" \
    --jq ".jobs[] | select(.name | test(\"${arch}\")) | .id") || return "$GH_UNAVAILABLE"
  job_id=$(printf '%s\n' "$jobs" | head -1)
  if ! [[ "$job_id" =~ ^[0-9]+$ ]]; then
    echo "Error: no ${arch} job in run ${run_id}" >&2
    return 1
  fi

  logs=$(gh api "repos/${REPO}/actions/jobs/${job_id}/logs") || return "$GH_UNAVAILABLE"
  image=$(printf '%s\n' "$logs" | grep -oP "Creating GCE image: \K[a-z0-9-]+" | head -1)
  if [ -z "$image" ]; then
    echo "Error: no GCE image logged for ${arch} in job ${job_id}" >&2
    return 1
  fi

  echo "Image: ${image} (arch: ${arch}, run: ${run_id})" >&2
  echo "$image"
}

# --- 1. Resolve image names ------------------------------------------------

IMAGES_RC=0
if [ -z "$IMAGE_X64" ] || [ -z "$IMAGE_ARM64" ]; then
  echo ""
  echo "--- Fetching latest PostgreSQL GCE images ---"
  [ -n "$IMAGE_X64" ] || IMAGE_X64=$(fetch_gce_image x64) || IMAGES_RC=$?
  [ -n "$IMAGE_ARM64" ] || IMAGE_ARM64=$(fetch_gce_image arm64) || IMAGES_RC=$?
fi

if [ "$IMAGES_RC" -eq "$GH_UNAVAILABLE" ]; then
  echo "WARNING: GitHub unreachable — pg_gce_image left unchanged." >&2
  echo "Pass --image-x64/--image-arm64 to set them without GitHub." >&2
  IMAGE_X64=""
  IMAGE_ARM64=""
elif [ "$IMAGES_RC" -ne 0 ]; then
  exit "$IMAGES_RC"
fi

# --- 2. Verify each image is readable by the cell service account ----------

verify_image() {
  local image="$1"
  if gcloud compute images describe "$image" \
       --project="$IMAGE_PROJECT" \
       --impersonate-service-account="$GCP_CELL_SERVICE_ACCOUNT" \
       --format="value(name)" > /dev/null 2>&1; then
    echo "  ${image}: readable in ${IMAGE_PROJECT}"
  else
    echo "ERROR: ${GCP_CELL_SERVICE_ACCOUNT} cannot read image ${image} in ${IMAGE_PROJECT}." >&2
    echo "Access is granted per-image via the resource-manager tags the build binds," >&2
    echo "so a new image may need its tag binding, or the name may be wrong." >&2
    exit 1
  fi
}

if [ -n "$IMAGE_X64" ] && [ -n "$IMAGE_ARM64" ]; then
  echo ""
  echo "--- Verifying image access ---"
  verify_image "$IMAGE_X64"
  verify_image "$IMAGE_ARM64"
fi

# --- 3. Location, credential, feature flags, pg_gce_image ------------------

echo ""
echo "--- Creating location and credentials ---"

RACK_ENV=development bundle exec ruby -r ./loader -e '
  $stdout.sync = true
  region, gcp_project, service_account, image_x64, image_arm64, pg_versions_csv = ARGV
  location_name = "gcp-#{region}"
  display_name = "#{location_name}-cell-0"

  project = Project.first(name: "default") or abort "ERROR: no project named \"default\". Run register-pg-project.sh first."

  DB.transaction do
    location = Location.first(project_id: project.id, name: location_name)
    if location
      puts "Location #{display_name.inspect} already exists (id: #{location.id})"
    else
      location = Location.create(
        name: location_name,
        display_name:,
        ui_name: display_name,
        visible: true,
        provider: "gcp",
        project_id: project.id,
      )
      puts "Created location #{display_name.inspect} (id: #{location.id})"
    end

    # credentials_json nil selects the impersonation branch in
    # LocationCredentialGcp#auth_credentials: the developer ADC impersonates the
    # cell service account, so no key material is stored.
    if LocationCredentialGcp[location.id]
      LocationCredentialGcp.where(id: location.id)
        .update(project_id: gcp_project, service_account_email: service_account, credentials_json: nil)
      puts "Updated GCP credential (project: #{gcp_project}, sa: #{service_account})"
    else
      LocationCredentialGcp.create_with_id(location.id,
        project_id: gcp_project,
        service_account_email: service_account,
        credentials_json: nil)
      puts "Created GCP credential (project: #{gcp_project}, sa: #{service_account})"
    end

    # c4a-* are on unless a project explicitly opts out (see
    # PostgresResource::Gcp::DEFAULT_ENABLED_FAMILIES); the rest are off by
    # default. z3 is left alone: it needs a per-project allowlist from Google.
    families = %w[c4a-standard c4a-highmem c4-standard c4-highmem c4d-standard c4d-highmem]
    families.each { project.send(:"set_ff_enable_#{it.tr("-", "_")}", true) }
    puts "Enabled GCP families: #{families.join(", ")}"

    # A column, not a feature flag: each GCP resource gets its own VPC.
    project.update(gcp_dedicated_subnet_vpcs: true)
    puts "Enabled gcp_dedicated_subnet_vpcs"
  end

  if image_x64.to_s.empty? || image_arm64.to_s.empty?
    puts "Skipping pg_gce_image (no image names resolved)"
  else
    pg_versions = Sequel.pg_array(pg_versions_csv.split(","), :text)
    DB.transaction do
      DB.run "SET LOCAL clickgres.bypass_dml_blocker__pg_gce_image = %s" % DB.literal("true")
      {"x64" => image_x64, "arm64" => image_arm64}.each do |arch, name|
        # Drop the other rows for this arch rather than leaving them alongside.
        # Location::Gcp#pg_gce_image picks .order(:gce_image_name).first, so a
        # stale upstream row -- whose image does not exist in our hosting
        # project -- could win on name ordering alone.
        stale = DB[:pg_gce_image].where(arch:).exclude(gce_image_name: name)
        removed = stale.all.map { it[:gce_image_name] }
        stale.delete
        puts "Removed stale #{arch} image row(s): #{removed.join(", ")}" unless removed.empty?

        DB[:pg_gce_image].insert_conflict(
          target: [:arch, :gce_image_name],
          update: {pg_versions:},
        ).insert(gce_image_name: name, arch:, pg_versions:)
        puts "pg_gce_image #{arch}: #{name} (pg #{pg_versions_csv})"
      end
    end
  end

  # First call that actually exercises impersonation plus the compute API, and
  # it populates location_az, which the VM nexus needs to pick a zone.
  location = Location.first(project_id: project.id, name: location_name)
  zones = location.azs.map(&:az)
  puts "Zones discovered for #{location_name}: #{zones.sort.join(", ")}"
' -- "$REGION" "$GCP_PROJECT_ID" "$GCP_CELL_SERVICE_ACCOUNT" "$IMAGE_X64" "$IMAGE_ARM64" "$PG_VERSIONS"

echo ""
echo "=== Done: gcp-${REGION}-cell-0 ==="
