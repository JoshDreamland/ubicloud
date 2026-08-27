#!/bin/bash
# List all PostgresServer resources and their states, across every location
# (AWS and GCP alike).
#
# The location list is derived from the resources themselves rather than
# hard-coded, so a newly registered location — e.g. gcp-us-east4-cell-0 from
# register-pg-gcp-region.sh — shows up without touching this script. The API is
# queried per location because that is the only path that yields the canonical
# `state`; the strand labels come from the database.
#
# Usage:
#   list-postgres-resources.sh [--location NAME]
#     --location: restrict to one location (default: all with resources)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

ONLY_LOCATION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --location) ONLY_LOCATION="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# display_name, not name: routes/project/location.rb resolves the API path
# segment by display_name.
locations=$(cd "$PROJECT_ROOT" && bundle exec ruby -e "
require_relative 'loader'
only = ARGV[0].to_s
names = PostgresResource.all.filter_map { it.location&.display_name }.uniq
names.select! { it == only } unless only.empty?
puts names.sort
" -- "$ONLY_LOCATION")

if [ -z "$locations" ]; then
  echo "No PostgreSQL resources found."
  exit 0
fi

combined='[]'
while read -r loc; do
  [ -z "$loc" ] && continue
  resp=$("$SCRIPT_DIR/invoke_ubicloud_api_curl.sh" GET "/project/default/location/$loc/postgres")
  combined=$(jq -n --argjson acc "$combined" --argjson r "$resp" --arg loc "$loc" \
    '$acc + [ ($r.items // [])[] | . + {_location: $loc} ]')
done <<< "$locations"

strand_labels=$(cd "$PROJECT_ROOT" && bundle exec ruby -e "
require_relative 'loader'
PostgresServer.all.each do |s|
  res = s.resource
  next unless res
  role = s.primary? ? 'primary' : 'replica'
  label = s.strand&.label || 'n/a'
  puts \"#{res.name}\t#{role}\t#{label}\"
end
")

echo "$combined" | python3 -c "
import json, sys

items = json.load(sys.stdin)

if not items:
    print('No PostgreSQL resources found.')
    sys.exit(0)

strand_lines = '''$strand_labels'''.strip().splitlines()
labels = {}
for line in strand_lines:
    if not line.strip():
        continue
    parts = line.split('\t')
    name, role, label = parts[0], parts[1], parts[2]
    labels.setdefault(name, []).append(f'{role}={label}')

print(f\"{'LOCATION':<22} {'NAME':<24} {'STATE':<12} {'SIZE':<18} {'HA':<8} {'VER':<5} {'NEXUS LABELS'}\")
print('-' * 122)
for r in sorted(items, key=lambda x: (x['_location'], x['name'])):
    nexus = ', '.join(labels.get(r['name'], []))
    print(f\"{r['_location']:<22} {r['name']:<24} {r['state']:<12} {r.get('vm_size',''):<18} {r.get('ha_type',''):<8} {r.get('version',''):<5} {nexus}\")
"
