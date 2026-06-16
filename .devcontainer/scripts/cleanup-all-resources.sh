#!/usr/bin/env bash
# Tear down ALL Postgres resources on this ClickHouse-fork onebox and confirm the
# Ubicloud-side records reach a terminal (destroyed) state.
#
#   1. Delete every Postgres resource via the API (the normal customer drop path).
#   2. Force-destroy any timelines left behind — timelines are intentionally
#      retained after a database is dropped, so the drop above does not remove them.
#   3. Confirm PostgresResource / PostgresServer / PostgresTimeline and their
#      associated metadata + strands are all gone.
#
# AWS-side artifacts (S3 buckets, IAM policies) are NOT inspected here; this only
# asserts Ubicloud's own state. Steps 2-3 run in the companion Ruby script, which
# also acts as a safety net for any resources the API list did not cover.
#
# Usage: cleanup-all-resources.sh [location]   (default: us-west-2-cell-0)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

LOCATION="${1:-us-west-2-cell-0}"
SCRIPT_DIR=".devcontainer/scripts"
API="$SCRIPT_DIR/invoke_ubicloud_api_curl.sh"

echo "=== Deleting all Postgres resources via API (location: $LOCATION) ==="
names="$("$API" GET "/project/default/location/$LOCATION/postgres" 2>/dev/null | jq -r '.items[]?.name // empty' || true)"
if [ -z "$names" ]; then
  echo "  none found via API"
else
  for name in $names; do
    echo "  DELETE $name"
    "$API" DELETE "/project/default/location/$LOCATION/postgres/$name" >/dev/null 2>&1 || true
  done
fi

echo "=== Draining, force-destroying timelines, and confirming terminal state ==="
exec bundle exec ruby -r ./loader "$SCRIPT_DIR/cleanup-all-resources.rb"
