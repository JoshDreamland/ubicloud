#!/usr/bin/env bash
# Establishes Application Default Credentials for the GCP locations.
#
# Usage: gcp-adc-login.sh
#   GCP_PROJECT_ID            project the cell runs in (set in docker-compose.yml)
#   GCP_CELL_SERVICE_ACCOUNT  service account to impersonate
set -euo pipefail

: "${GCP_PROJECT_ID:?GCP_PROJECT_ID is not set. Ensure it is defined in docker-compose.yml or exported in your shell.}"

if ! command -v gcloud > /dev/null 2>&1; then
  echo "ERROR: gcloud is not installed. Run: bash .devcontainer/scripts/install-gcloud.sh" >&2
  exit 1
fi

echo "=== GCP Application Default Credentials ==="

# print-access-token rather than `gcloud auth list`: the latter reports the
# gcloud user account, which is a different credential from ADC. Only ADC is
# what the googleauth gem reads.
if gcloud auth application-default print-access-token > /dev/null 2>&1; then
  echo "ADC already present"
elif [ ! -t 0 ]; then
  # --no-launch-browser waits on a pasted verification code, which nothing will
  # ever type here, so a non-interactive caller would block until its job times
  # out. Say what to do instead of hanging.
  echo "ERROR: no Application Default Credentials and no terminal to log in from." >&2
  echo "Run '$0' from an interactive shell, or skip GCP entirely with" >&2
  echo "'prepare-pg-ubicloud.sh --no-gcp' (or ENABLE_GCP=false)." >&2
  exit 1
else
  # No browser in the container, so this prints a URL to paste.
  gcloud auth application-default login --no-launch-browser
fi

# Without a quota project, Google APIs bill quota to whichever project the
# credential came from and some refuse the call outright.
gcloud auth application-default set-quota-project "$GCP_PROJECT_ID" 2>&1 | tail -1

if [ -z "${GCP_CELL_SERVICE_ACCOUNT:-}" ]; then
  echo ""
  echo "GCP_CELL_SERVICE_ACCOUNT is not set, so impersonation cannot be verified." >&2
  echo "Service accounts visible in ${GCP_PROJECT_ID}:" >&2
  gcloud iam service-accounts list --project="$GCP_PROJECT_ID" \
    --format="value(email)" 2>/dev/null | sed "s/^/  /" >&2 || true
  echo "" >&2
  echo "Set it in .devcontainer/docker-compose.yml (see the commented entry) and" >&2
  echo "re-run this script." >&2
  exit 1
fi

echo ""
echo "=== Verifying impersonation of ${GCP_CELL_SERVICE_ACCOUNT} ==="
if gcloud auth print-access-token \
     --impersonate-service-account="$GCP_CELL_SERVICE_ACCOUNT" > /dev/null 2>&1; then
  echo "Impersonation OK"
else
  echo "ERROR: cannot impersonate ${GCP_CELL_SERVICE_ACCOUNT}." >&2
  echo "The account needs to grant you roles/iam.serviceAccountTokenCreator:" >&2
  echo "  gcloud iam service-accounts add-iam-policy-binding ${GCP_CELL_SERVICE_ACCOUNT} \\" >&2
  echo "    --member=\"user:\$(gcloud config get-value account)\" \\" >&2
  echo "    --role=roles/iam.serviceAccountTokenCreator --project=${GCP_PROJECT_ID}" >&2
  exit 1
fi

# The first call the location actually makes is zone discovery
# (Location::Gcp#set_gcp_azs), so exercise the compute API as the cell SA now.
echo ""
echo "=== Checking compute API access as the cell service account ==="
if ZONES=$(gcloud compute zones list --project="$GCP_PROJECT_ID" \
             --impersonate-service-account="$GCP_CELL_SERVICE_ACCOUNT" \
             --format="value(name)" 2>/dev/null) && [ -n "$ZONES" ]; then
  echo "compute.zones.list OK ($(printf '%s\n' "$ZONES" | wc -l) zones)"
else
  echo "WARNING: compute.zones.list failed or returned nothing. The cell service" >&2
  echo "account likely lacks roles/compute.admin, or the Compute Engine API is not" >&2
  echo "enabled on ${GCP_PROJECT_ID}. See GCP_DEVCONTAINER_PLAN.md section 5." >&2
fi

echo ""
echo "=== Done ==="
