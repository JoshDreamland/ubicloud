#!/bin/bash
# Replaces the marked block in the gitignored .env.rb with the current contents
# of .devcontainer/env-overrides.rb.
#
# Usage: sync-env-overrides.sh [--check]
#   --check: report drift and exit 1 without writing (pre-flight / CI)
#
# ENV is read at process start, so after a change restart the control plane:
#   .devcontainer/scripts/start-foreman.sh --restart

set -e

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_RB="$REPO_ROOT/.env.rb"
OVERRIDES="$REPO_ROOT/.devcontainer/env-overrides.rb"

CHECK=0
if [ "$1" = "--check" ]; then
  CHECK=1
elif [ -n "$1" ]; then
  echo "Unknown option: $1" >&2
  echo "Usage: $0 [--check]" >&2
  exit 1
fi

if [ ! -f "$OVERRIDES" ]; then
  echo "No env-overrides.rb — nothing to sync."
  exit 0
fi

if [ ! -f "$ENV_RB" ]; then
  echo "ERROR: $ENV_RB does not exist. Generate it first with: rake overwrite_envrb" >&2
  exit 1
fi

python3 - "$ENV_RB" "$OVERRIDES" "$CHECK" <<'PY'
import re
import sys

env_rb_path, overrides_path, check = sys.argv[1], sys.argv[2], sys.argv[3] == "1"

BEGIN = "### DEVCONTAINER ###"
END = "### /DEVCONTAINER ###"

with open(env_rb_path) as f:
    env_rb = f.read()
with open(overrides_path) as f:
    overrides = f.read().strip("\n")

block = f"{BEGIN}\n{overrides}\n{END}\n"

# Markers are matched as whole lines, so a marker named in prose or in a comment
# elsewhere in .env.rb is not mistaken for the real thing.
lines = env_rb.splitlines(keepends=True)
begins = [i for i, line in enumerate(lines) if line.strip() == BEGIN]
ends = [i for i, line in enumerate(lines) if line.strip() == END]

if len(begins) > 1 or len(ends) > 1:
    sys.exit(f"ERROR: {env_rb_path} has {len(begins)} '{BEGIN}' and {len(ends)} "
             f"'{END}' lines; expected at most one of each. Fix it by hand.")
if len(begins) != len(ends):
    sys.exit(f"ERROR: {env_rb_path} has an unbalanced marker pair "
             f"({len(begins)} begin, {len(ends)} end). Fix it by hand.")

if begins:
    start, stop = begins[0], ends[0]
    if stop < start:
        sys.exit(f"ERROR: '{END}' precedes '{BEGIN}' in {env_rb_path}. Fix it by hand.")
    updated = "".join(lines[:start]) + block + "".join(lines[stop + 1:])
    action = "Updated"
else:
    updated = env_rb.rstrip("\n") + "\n\n" + block
    action = "Added"

if updated == env_rb:
    print("env-overrides.rb block already current in .env.rb")
    sys.exit(0)

if check:
    sys.exit(f"ERROR: .env.rb override block is stale (would be {action.lower()}). "
             "Run .devcontainer/scripts/sync-env-overrides.sh")

with open(env_rb_path, "w") as f:
    f.write(updated)

# A pre-marker .env.rb carries an unmarked copy of the overrides that this
# script cannot safely identify. The block is written last so it wins, but say
# so rather than leaving a silent duplicate behind.
# Assignments only: env-overrides.rb *reads* ENV["RACK_ENV"] to guard its test
# branch, and .env.rb assigns it, which is not a duplicate override.
assign = re.compile(r'ENV\["([A-Z_0-9]+)"\]\s*(?:\|\|)?=')
updated_lines = updated.splitlines(keepends=True)
block_start = next(i for i, line in enumerate(updated_lines) if line.strip() == BEGIN)
outside = "".join(updated_lines[:block_start])
dupes = sorted(set(assign.findall(overrides)) & set(assign.findall(outside)))
if dupes:
    print("WARNING: .env.rb also assigns these keys outside the block, likely a "
          "leftover pre-marker copy: " + ", ".join(dupes), file=sys.stderr)
    print("         The block is last, so it wins. Delete the older copy when "
          "convenient.", file=sys.stderr)

print(f"{action} the env-overrides.rb block in .env.rb "
      "(restart foreman to load it: .devcontainer/scripts/start-foreman.sh --restart)")
PY
