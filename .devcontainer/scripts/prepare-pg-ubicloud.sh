#!/bin/bash
# Prepares the Ubicloud environment for PostgreSQL development.
# Authenticates with GitHub, fetches latest AMIs, and updates the database.
#
# Usage: .devcontainer/prepare-pg-ubicloud.sh [--region us-west-2] [--region us-east-1]
#   --region: AWS region(s) to update (default: us-west-2). Can be specified multiple times.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REGIONS=()

: "${AWS_ASSUME_ROLE:?AWS_ASSUME_ROLE is not set. Ensure it is defined in docker-compose.yml or exported in your shell.}"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)
      REGIONS+=("$2")
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: $0 [--region us-west-2] [--region us-east-1]" >&2
      exit 1
      ;;
  esac
done

# Default to us-west-2 if no regions specified
if [ ${#REGIONS[@]} -eq 0 ]; then
  REGIONS=("us-west-2")
fi

# 0. Sync mise-managed tools (ruby/nodejs/golang/victoria-metrics) from
#    mise.toml and re-bundle if Ruby was bumped by an upstream merge.
echo ""
echo "=== Syncing mise tools from mise.toml ==="
"$SCRIPT_DIR/sync-tool-versions.sh"
# After a tool-version bump, the parent shell's PATH still points at the
# previously-active versions. Refresh this script's env so the remaining
# steps (rake, bundle exec, foreman) run under the new active tools.
MISE_BIN="${MISE:-/home/vscode/.local/bin/mise}"
if [ -x "$MISE_BIN" ]; then
  eval "$("$MISE_BIN" env -s bash)"
fi

# 1. Run database migrations to latest version
echo ""
echo "=== Running database migrations (rake dev_up) ==="
(cd "$SCRIPT_DIR/../.." && bundle exec rake dev_up)

# 2. Create default project with private_locations enabled
"$SCRIPT_DIR/register-pg-project.sh"

# 3. GitHub authentication
echo ""
echo "=== GitHub CLI authentication ==="
# gh auth status exits 0 even when it reports the stored token as invalid
# (gh 2.45), so probe the API instead: an expired credential is caught here
# rather than surfacing as a confusing 401 several steps later. rate_limit
# validates credentials and is exempt from the rate limit itself, so it stays
# usable once the core quota is exhausted.
gh_usable() {
  gh api rate_limit --silent 2>/dev/null
}

GH_AUTH_OK=1
if gh_usable; then
  echo "gh credentials OK"
elif [ -n "${GH_TOKEN:-}" ]; then
  GH_AUTH_OK=0
  echo "WARNING: GH_TOKEN is set but GitHub rejected it. Unset GH_TOKEN to fall back to 'gh auth login'." >&2
elif [ -t 0 ] && gh auth login && gh_usable; then
  echo "gh credentials OK"
else
  GH_AUTH_OK=0
  echo "WARNING: gh has no valid credentials — run 'gh auth login'" >&2
fi

# 4. Download AWS config (skip when credentials are already in environment)
AWS_CONFIG_PATH="${AWS_CONFIG_FILE:-$HOME/.aws/config}"

# A usable config has at least one [profile ...] section. A truncated file or a
# GitHub error body has none, so this also rejects a failed download.
aws_config_usable() {
  [ -s "$AWS_CONFIG_PATH" ] && grep -q '^\[profile ' "$AWS_CONFIG_PATH"
}

fetch_aws_config() {
  local out="$1"
  if gh api /repos/ClickHouse/data-plane-configuration/contents/aws-config \
       -H "Accept: application/vnd.github.raw" > "$out" 2>/dev/null &&
     grep -q '^\[profile ' "$out"; then
    return 0
  fi
  # The REST core quota is a separate bucket from GraphQL, so a 403 above often
  # still leaves this path working.
  echo "REST download failed — retrying over GraphQL" >&2
  gh api graphql -f query='{repository(owner:"ClickHouse",name:"data-plane-configuration"){object(expression:"HEAD:aws-config"){... on Blob {text}}}}' \
    --jq '.data.repository.object.text' > "$out" 2>/dev/null &&
    grep -q '^\[profile ' "$out"
}

if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
  echo ""
  echo "=== AWS credentials available in environment — skipping AWS config download ==="
elif [ "$GH_AUTH_OK" -eq 0 ] && aws_config_usable; then
  echo ""
  echo "=== gh unusable — keeping existing $AWS_CONFIG_PATH ($(grep -c '^\[profile ' "$AWS_CONFIG_PATH") profiles) ==="
else
  echo ""
  echo "=== Downloading AWS config ==="
  mkdir -p "$(dirname "$AWS_CONFIG_PATH")"
  sudo chown -R "$(id -u):$(id -g)" "$(dirname "$AWS_CONFIG_PATH")"
  # Download to a temp file first: redirecting straight into $AWS_CONFIG_PATH
  # truncates it before gh runs, so any failure replaces every profile with an
  # error body.
  TMP_AWS_CONFIG="$(mktemp)"
  if fetch_aws_config "$TMP_AWS_CONFIG"; then
    mv "$TMP_AWS_CONFIG" "$AWS_CONFIG_PATH"
    echo "AWS config written to $AWS_CONFIG_PATH"
  else
    rm -f "$TMP_AWS_CONFIG"
    if aws_config_usable; then
      echo "WARNING: download failed — keeping existing $AWS_CONFIG_PATH ($(grep -c '^\[profile ' "$AWS_CONFIG_PATH") profiles)" >&2
    else
      echo "ERROR: could not download AWS config and $AWS_CONFIG_PATH has no usable profiles." >&2
      exit 1
    fi
  fi
fi

# 5. Register regions (create locations + fetch and update AMIs)
# The AMI refresh needs GitHub. Exit status 78 means the API was unreachable,
# in which case the location was still created and the existing AMI rows are
# left alone, so keep going to the SSO login and foreman restart. Any other
# failure is a real error and still aborts.
GH_REGION_UNAVAILABLE=78
for REGION in "${REGIONS[@]}"; do
  REGION_RC=0
  "$SCRIPT_DIR/register-pg-region.sh" "$REGION" "$AWS_ASSUME_ROLE" || REGION_RC=$?
  if [ "$REGION_RC" -eq "$GH_REGION_UNAVAILABLE" ]; then
    echo "WARNING: ${REGION} AMI refresh skipped — GitHub unreachable, existing AMI rows unchanged" >&2
  elif [ "$REGION_RC" -ne 0 ]; then
    exit "$REGION_RC"
  fi
done

"$SCRIPT_DIR/aws-sso-login.sh"

# Start foreman last so respirate boots with the fully prepared AWS profile,
# downloaded ~/.aws/config, registered locations, and a valid SSO session.
"$SCRIPT_DIR/start-foreman.sh" --restart

echo ""
echo "=== Done ==="
