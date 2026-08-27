#!/bin/bash
# Output eval-able env vars for a Postgres resource.
#
# Always: PG_NAME, PG_LOCATION, PG_PROVIDER, PG_IP, PG_PWD, SRV_INST
#   aws:  SRV_AZ    (physical AZ id, e.g. usw2-az1)
#   gcp:  SRV_ZONE  (full zone name, e.g. us-east4-c)
#
# PG_LOCATION defaults to us-west-2-cell-0; set it for any other location, e.g.
#   PG_LOCATION=gcp-us-east4-cell-0 pg-info.sh <name>
#
# Usage:  eval "$(.devcontainer/scripts/bench/pg-info.sh <resource-name>)"
set -euo pipefail

NAME="${1:?usage: $0 <pg-resource-name>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
INVOKE="$SCRIPT_DIR/../invoke_ubicloud_api_curl.sh"

# Public IP + password from the API
PG_LOCATION="${PG_LOCATION:-us-west-2-cell-0}"
INFO=$("$INVOKE" GET "/project/default/location/$PG_LOCATION/postgres/$NAME" 2>/dev/null)
PG_IP=$(jq -r '.hostname // empty' <<<"$INFO")
PG_PWD=$(jq -r '.password // empty' <<<"$INFO")

# Placement comes from the Ubicloud DB, not the API, and is provider-shaped:
# AWS exposes an instance id plus a *physical* AZ id (stable across accounts),
# GCP an instance name plus a zone (globally unambiguous, so no id/name split).
# Errors are deliberately NOT swallowed here -- a nil aws_instance used to make
# this emit empty placement vars, which silently sent the bench client to the
# wrong AZ.
INSTANCE_INFO=$(cd "$PROJECT_ROOT" && bundle exec ruby -r ./loader -e "
r = PostgresResource.first(name: ARGV[0]) or abort 'ERROR: no PostgresResource named ' + ARGV[0]
vm = r.representative_server.vm
case r.location.provider
when 'aws'
  ai = vm.aws_instance or abort 'ERROR: no aws_instance for ' + vm.name
  puts \"aws #{ai.instance_id} #{ai.az_id}\"
when 'gcp'
  gr = vm.vm_gcp_resource or abort 'ERROR: no vm_gcp_resource for ' + vm.name
  region = r.location.name.delete_prefix('gcp-')
  puts \"gcp #{vm.name} #{region}-#{gr.location_az.az}\"
else
  abort 'ERROR: unsupported provider ' + r.location.provider.to_s
end
" -- "$NAME")

PG_PROVIDER=$(echo "$INSTANCE_INFO" | awk '{print $1}')
SRV_INST=$(echo "$INSTANCE_INFO" | awk '{print $2}')
SRV_PLACEMENT=$(echo "$INSTANCE_INFO" | awk '{print $3}')

# Emit shell-quoted assignments so callers can safely `eval` even when values
# contain shell metacharacters (the password is API-provided and could
# legitimately include $, `, etc.).
printf 'export PG_NAME=%q\n'     "$NAME"
printf 'export PG_LOCATION=%q\n' "$PG_LOCATION"
printf 'export PG_PROVIDER=%q\n' "$PG_PROVIDER"
printf 'export PG_IP=%q\n'       "$PG_IP"
printf 'export PG_PWD=%q\n'      "$PG_PWD"
printf 'export SRV_INST=%q\n'    "$SRV_INST"
if [ "$PG_PROVIDER" = "gcp" ]; then
  printf 'export SRV_ZONE=%q\n'  "$SRV_PLACEMENT"
else
  printf 'export SRV_AZ=%q\n'    "$SRV_PLACEMENT"
fi
