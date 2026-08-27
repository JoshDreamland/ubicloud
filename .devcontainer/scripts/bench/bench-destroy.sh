#!/bin/bash
# Tear down a benchmark-client VM and everything bench-provision.sh created for
# it, plus the Postgres firewall rules opened for this client. The provider is
# read from /tmp/bench_meta_<vm-name>:
#   aws: EC2 instance, security group, route table, subnet, internet gateway,
#        VPC, keypair
#   gcp: GCE instance, firewall rule, subnet, VPC
#
# Usage: bench-destroy.sh <vm-name>

set -euo pipefail

: "${AWS_PROFILE:=pg-dev-postgresqladmindev}"
export AWS_PROFILE

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INVOKE="$SCRIPT_DIR/../invoke_ubicloud_api_curl.sh"

NAME="${1:?Usage: bench-destroy.sh <vm-name>}"
META_FILE="/tmp/bench_meta_$NAME"
[ -f "$META_FILE" ] || { echo "Missing $META_FILE — was this VM provisioned via bench-provision.sh?" >&2; exit 1; }
# shellcheck disable=SC1090
. "$META_FILE"

PG_LOCATION="${PG_LOCATION:-us-west-2-cell-0}"

echo "=== bench-destroy ==="
echo "vm_name:     $VM_NAME"
echo "provider:    ${PG_PROVIDER:-aws}"
echo "instance:    $INSTANCE_ID"
echo "region:      $REGION"
echo "pg_resource: $PG_RESOURCE"

# --- 1. Close the Postgres firewall rules we opened ---
if [ -n "${PG_FIREWALL_RULE_DESC:-}" ]; then
  echo "Removing PG firewall rules tagged description=$PG_FIREWALL_RULE_DESC..."
  RULES_JSON=$("$INVOKE" GET "/project/default/location/$PG_LOCATION/postgres/$PG_RESOURCE/firewall-rule" 2>/dev/null || echo '{"items":[]}')
  echo "$RULES_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data.get('items', []):
    if r.get('description') == '$PG_FIREWALL_RULE_DESC':
        print(r['id'])
" | while read -r rule_id; do
    [ -n "$rule_id" ] || continue
    echo "  delete $rule_id"
    "$INVOKE" DELETE "/project/default/location/$PG_LOCATION/postgres/$PG_RESOURCE/firewall-rule/$rule_id" -o /dev/null -w "%{http_code}\n" || true
  done
fi

if [ "${PG_PROVIDER:-aws}" = "gcp" ]; then
  GCLOUD=(gcloud --project="$GCP_PROJECT_ID" --quiet)
  # wait_for_vm_state.sh reads this from the environment; the meta file only
  # sourced it into a shell variable.
  export GCP_PROJECT_ID

  # GCE keeps references to a deleted instance for a while, so the subnet and
  # then the network refuse to go until those drain. Retry rather than firing
  # once -- this is the same trap that leaks tag keys in the control plane's own
  # GCP subnet teardown.
  retry_delete() {
    local what="$1"; shift
    local out attempt
    for attempt in $(seq 1 12); do
      if out=$("$@" 2>&1); then
        echo "  deleted $what"
        return 0
      fi
      if grep -qiE "was not found|NOT_FOUND|does not exist|404" <<<"$out"; then
        echo "  $what already gone"
        return 0
      fi
      sleep 10
    done
    echo "  WARNING: $what survived $attempt attempts -- LEAKED: $(head -1 <<<"$out")" >&2
    return 1
  }

  echo "Deleting instance $VM_NAME in $GCP_ZONE..."
  "${GCLOUD[@]}" compute instances delete "$VM_NAME" --zone="$GCP_ZONE" >/dev/null 2>&1 || true
  "$SCRIPT_DIR/wait_for_vm_state.sh" "$VM_NAME" TERMINATED 300 "$GCP_ZONE" || true

  echo "Deleting firewall rule $GCP_FW_RULE..."
  "${GCLOUD[@]}" compute firewall-rules delete "$GCP_FW_RULE" >/dev/null 2>&1 || true

  echo "Deleting subnet $GCP_SUBNET (retrying while GCE drains interface refs)..."
  retry_delete "subnet $GCP_SUBNET" "${GCLOUD[@]}" compute networks subnets delete "$GCP_SUBNET" --region="$REGION" || true

  echo "Deleting network $GCP_NETWORK..."
  retry_delete "network $GCP_NETWORK" "${GCLOUD[@]}" compute networks delete "$GCP_NETWORK" || true
else
  # --- 2. Terminate EC2 instance and wait ---
  echo "Terminating $INSTANCE_ID..."
  aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null || true
  "$SCRIPT_DIR/wait_for_vm_state.sh" "$INSTANCE_ID" terminated 300 "$REGION" || true

  # --- 3. Delete keypair ---
  aws ec2 delete-key-pair --region "$REGION" --key-name "$KEY_NAME" 2>/dev/null || true

  # --- 4. Network teardown (dependency order: SG, RT, subnet, IGW, VPC) ---
  echo "Deleting SG $SG_ID..."
  aws ec2 delete-security-group --region "$REGION" --group-id "$SG_ID" 2>/dev/null || true

  echo "Disassociating + deleting route table $RTB_ID..."
  ASSOC=$(aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$RTB_ID" \
    --query 'RouteTables[0].Associations[].RouteTableAssociationId' --output text 2>/dev/null || true)
  for a in $ASSOC; do
    [ "$a" != "None" ] && aws ec2 disassociate-route-table --region "$REGION" --association-id "$a" 2>/dev/null || true
  done
  aws ec2 delete-route-table --region "$REGION" --route-table-id "$RTB_ID" 2>/dev/null || true

  echo "Deleting subnet $SUBNET_ID..."
  aws ec2 delete-subnet --region "$REGION" --subnet-id "$SUBNET_ID" 2>/dev/null || true

  echo "Detaching + deleting IGW $IGW_ID..."
  aws ec2 detach-internet-gateway --region "$REGION" --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" 2>/dev/null || true
  aws ec2 delete-internet-gateway --region "$REGION" --internet-gateway-id "$IGW_ID" 2>/dev/null || true

  echo "Deleting VPC $VPC_ID..."
  aws ec2 delete-vpc --region "$REGION" --vpc-id "$VPC_ID" 2>/dev/null || true
fi

# --- 5. Local cleanup ---
rm -f "$KEY_FILE" "${KEY_FILE}.pub" "$META_FILE"
echo "Removed $KEY_FILE, ${KEY_FILE}.pub, $META_FILE"
echo "Done."
