#!/bin/bash
# Poll a bench-client VM until it reaches a target state.
#
# Usage:
#   wait_for_vm_state.sh <instance-id|name> <state> [timeout_seconds] [region|zone]
#   wait_for_vm_state.sh i-0abcdef1234567890 running
#   wait_for_vm_state.sh i-0abcdef1234567890 terminated 600
#   wait_for_vm_state.sh bench-foo RUNNING 600 us-east4-c        # gcp
#
# The provider is inferred from the 4th argument: a GCP zone carries a trailing
# zone letter (us-east4-c) while an AWS region does not (us-west-2). That keeps
# the call sites in bench-provision/bench-destroy unchanged apart from passing a
# zone instead of a region.
#
# Exits 0 on success, 1 on timeout. For AWS, "terminated" also matches a missing
# instance; for GCP, so does "TERMINATED", since a deleted instance stops
# resolving entirely.
set -euo pipefail

: "${AWS_PROFILE:=pg-dev-postgresqladmindev}"
export AWS_PROFILE

INSTANCE_ID="${1:?Usage: wait_for_vm_state.sh <instance-id|name> <state> [timeout] [region|zone]}"
TARGET_STATE="${2:?Usage: wait_for_vm_state.sh <instance-id|name> <state> [timeout] [region|zone]}"
TIMEOUT="${3:-600}"
SCOPE="${4:-${AWS_REGION:-us-west-2}}"

# us-east4-c -> gcp zone; us-west-2 -> aws region.
if [[ "$SCOPE" =~ ^[a-z]+-[a-z]+[0-9]+-[a-z]$ ]]; then
  PROVIDER="gcp"
else
  PROVIDER="aws"
fi

read_state() {
  if [ "$PROVIDER" = "gcp" ]; then
    gcloud compute instances describe "$INSTANCE_ID" \
      --project="${GCP_PROJECT_ID:?GCP_PROJECT_ID is not set}" --zone="$SCOPE" \
      --format='value(status)' 2>/dev/null || echo "missing"
  else
    aws ec2 describe-instances --region "$SCOPE" --instance-ids "$INSTANCE_ID" \
      --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "missing"
  fi
}

gone_counts_as_target() {
  { [ "$PROVIDER" = "aws" ] && [ "$TARGET_STATE" = "terminated" ]; } ||
    { [ "$PROVIDER" = "gcp" ] && [ "$TARGET_STATE" = "TERMINATED" ]; }
}

INTERVAL=10
ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  STATE=$(read_state)
  [ -n "$STATE" ] || STATE="missing"
  echo "$(date +%H:%M:%S) $INSTANCE_ID state=$STATE"
  if [ "$STATE" = "$TARGET_STATE" ]; then
    echo "Reached state: $TARGET_STATE"
    exit 0
  fi
  if [ "$STATE" = "missing" ] && gone_counts_as_target; then
    echo "Instance no longer exists; treating as $TARGET_STATE."
    exit 0
  fi
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo "Timeout waiting for $INSTANCE_ID to reach state: $TARGET_STATE" >&2
exit 1
