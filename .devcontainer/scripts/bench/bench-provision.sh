#!/bin/bash
# Bootstrap a benchmark-client VM directly via the cloud CLI, in its own
# network, sized for a given core count, in the same zone/AZ as the target
# Postgres resource. Connectivity is plain SSH/SCP — ingress on port 22 is
# opened only to the dev container's current egress IP (auto-detected) or to
# the CIDR you pass via --ssh-cidr.
#
# The provider is taken from the target Postgres resource's location, so the
# same invocation works for both:
#   aws: EC2 instance in its own VPC/subnet/SG/IGW/route-table
#   gcp: GCE instance in its own VPC/subnet + a firewall rule (GCE needs no
#        internet gateway or route table objects for egress)
#
# Usage:
#   bench-provision.sh <pg-resource-name> --cores N \
#     [--instance-type T] [--name VM_NAME] [--az AZ_ID] \
#     [--ssh-cidr CIDR] [--hammerdb-image IMG]
#
#   PG_LOCATION=gcp-us-east4-cell-0 bench-provision.sh <name> --cores 4
#
# Defaults:
#   --az              Zone/AZ of the PG primary (from pg-info.sh)
#   --name            bench-<pg-name>-<rand>
#   --ssh-cidr        $(curl -s checkip.amazonaws.com)/32 — the dev container's
#                     current egress IP. If your egress IP changes mid-session
#                     SSH stops working; re-provision (cheap) or update the SG
#                     rule manually.
#   --hammerdb-image  tpcorg/hammerdb:latest
#
# Resource tags applied for cleanup: Project=ubicloud-bench BenchName=<vm-name>

set -euo pipefail

: "${AWS_PROFILE:=pg-dev-postgresqladmindev}"
export AWS_PROFILE

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INVOKE="$SCRIPT_DIR/../invoke_ubicloud_api_curl.sh"
PAYLOADS_DIR="$SCRIPT_DIR/vm-payloads"

PG_NAME="${1:-}"
[ -n "$PG_NAME" ] || { echo "Usage: bench-provision.sh <pg-resource-name> --cores N [opts]" >&2; exit 1; }
shift

CORES=""
VM_NAME=""
AZ_OVERRIDE=""
SSH_CIDR=""
HAMMERDB_IMAGE="tpcorg/hammerdb:latest"
INSTANCE_TYPE_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cores)          CORES="$2"; shift 2 ;;
    --instance-type)  INSTANCE_TYPE_OVERRIDE="$2"; shift 2 ;;
    --name)           VM_NAME="$2"; shift 2 ;;
    --az)             AZ_OVERRIDE="$2"; shift 2 ;;
    --ssh-cidr)       SSH_CIDR="$2"; shift 2 ;;
    --hammerdb-image) HAMMERDB_IMAGE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$INSTANCE_TYPE_OVERRIDE" ] && [ -z "$CORES" ]; then
  echo "One of --cores or --instance-type is required" >&2; exit 1
fi

# --- 1. Discover PG resource details (also fixes the provider) ---
eval "$("$SCRIPT_DIR/pg-info.sh" "$PG_NAME")"
[ -n "${PG_IP:-}"  ] || { echo "pg-info.sh did not return PG_IP for $PG_NAME"  >&2; exit 1; }
[ -n "${PG_PWD:-}" ] || { echo "pg-info.sh did not return PG_PWD for $PG_NAME" >&2; exit 1; }

# n2 for GCP: cheapest broadly-available amd64 family, needs no per-project
# allowlist, and amd64 is mandatory because HammerDB upstream ships x86_64 only
# (which also rules out matching the c4a/Axion PG side).
if [ -n "$INSTANCE_TYPE_OVERRIDE" ]; then
  VM_SIZE="$INSTANCE_TYPE_OVERRIDE"
elif [ "$PG_PROVIDER" = "gcp" ]; then
  case "$CORES" in
    2|4|8|16|32|64) VM_SIZE="n2-standard-$CORES" ;;
    *) echo "Unsupported --cores=$CORES for gcp (allowed: 2,4,8,16,32,64)" >&2; exit 1 ;;
  esac
else
  case "$CORES" in
    2)  VM_SIZE="m6id.large" ;;
    4)  VM_SIZE="m6id.xlarge" ;;
    8)  VM_SIZE="m6id.2xlarge" ;;
    16) VM_SIZE="m6id.4xlarge" ;;
    32) VM_SIZE="m6id.8xlarge" ;;
    64) VM_SIZE="m6id.16xlarge" ;;
    *)  echo "Unsupported --cores=$CORES (allowed: 2,4,8,16,32,64)" >&2; exit 1 ;;
  esac
fi

if [ "$PG_PROVIDER" = "gcp" ]; then
  [ -n "${SRV_ZONE:-}" ] || { echo "pg-info.sh did not return SRV_ZONE for $PG_NAME" >&2; exit 1; }
  GCP_ZONE="${AZ_OVERRIDE:-$SRV_ZONE}"
  REGION="${GCP_ZONE%-*}"
  AZ_ID="$GCP_ZONE"
  : "${GCP_PROJECT_ID:?GCP_PROJECT_ID is not set. Ensure it is defined in docker-compose.yml or exported in your shell.}"
  # wait_for_vm_state.sh reads this from the environment.
  export GCP_PROJECT_ID
else
  [ -n "${SRV_AZ:-}" ] || { echo "pg-info.sh did not return SRV_AZ for $PG_NAME" >&2; exit 1; }
  REGION="${PG_LOCATION%-cell-*}"
  AZ_ID="${AZ_OVERRIDE:-$SRV_AZ}"
fi

[ -n "$VM_NAME" ] || VM_NAME="bench-$PG_NAME-$(printf '%04x' $RANDOM)"
META_FILE="/tmp/bench_meta_$VM_NAME"
KEY_FILE="/tmp/bench_ssh_key_$VM_NAME"

# --- 2. Auto-detect SSH ingress CIDR ---
if [ -z "$SSH_CIDR" ]; then
  MY_IP=$(curl -fsS --max-time 5 https://checkip.amazonaws.com | tr -d '\r\n')
  [ -n "$MY_IP" ] || { echo "Could not auto-detect egress IP; pass --ssh-cidr explicitly" >&2; exit 1; }
  SSH_CIDR="$MY_IP/32"
fi

echo "=== bench-provision (SSH) ==="
echo "pg_resource:    $PG_NAME"
echo "vm_name:        $VM_NAME"
echo "vm_size:        $VM_SIZE  (cores=$CORES)"
echo "region:         $REGION"
echo "az_id:          $AZ_ID"
echo "ssh_cidr:       $SSH_CIDR  (only this IP can reach port 22)"
echo

if [ "$PG_PROVIDER" = "gcp" ]; then
  # --- 3-7 (gcp). GCE needs no internet gateway or route table: the default
  # network route provides egress, so this is a shorter sequence than AWS.
  # Labels mirror the AWS tags so an orphan sweep can find leftovers.
  GCP_NETWORK="$VM_NAME-net"
  GCP_SUBNET="$VM_NAME-subnet"
  GCP_FW_RULE="$VM_NAME-allow-ssh"
  GCP_LABELS="project=ubicloud-bench,bench-name=$VM_NAME"
  GCLOUD=(gcloud --project="$GCP_PROJECT_ID" --quiet)
  VM_USER="ubuntu"

  echo "zone:           $GCP_ZONE"
  echo "image:          ubuntu-2604-lts-amd64  (amd64, pinned for HammerDB compatibility)"

  [ -f "$KEY_FILE" ] || ssh-keygen -t ed25519 -N "" -C "$VM_NAME" -f "$KEY_FILE" >/dev/null

  echo "Creating VPC $GCP_NETWORK + subnet 10.99.1.0/24 in $REGION..."
  "${GCLOUD[@]}" compute networks create "$GCP_NETWORK" --subnet-mode=custom >/dev/null
  "${GCLOUD[@]}" compute networks subnets create "$GCP_SUBNET" \
    --network="$GCP_NETWORK" --region="$REGION" --range=10.99.1.0/24 >/dev/null
  "${GCLOUD[@]}" compute firewall-rules create "$GCP_FW_RULE" \
    --network="$GCP_NETWORK" --allow=tcp:22 --source-ranges="$SSH_CIDR" \
    --description="Bench client SSH for $VM_NAME" >/dev/null
  echo "NETWORK=$GCP_NETWORK  SUBNET=$GCP_SUBNET  FW=$GCP_FW_RULE (port 22 from $SSH_CIDR)"

  echo "Launching $VM_SIZE in $GCP_ZONE..."
  "${GCLOUD[@]}" compute instances create "$VM_NAME" \
    --zone="$GCP_ZONE" --machine-type="$VM_SIZE" --subnet="$GCP_SUBNET" \
    --image-family=ubuntu-2604-lts-amd64 --image-project=ubuntu-os-cloud \
    --boot-disk-size=100GB --boot-disk-type=pd-balanced \
    --labels="$GCP_LABELS" \
    --metadata="ssh-keys=${VM_USER}:$(cat "${KEY_FILE}.pub")" >/dev/null
  # No separate instance id on GCE: the name is the handle, scoped by zone.
  INSTANCE_ID="$VM_NAME"

  "$SCRIPT_DIR/wait_for_vm_state.sh" "$VM_NAME" RUNNING 600 "$GCP_ZONE"

  VM_IP=$("${GCLOUD[@]}" compute instances describe "$VM_NAME" --zone="$GCP_ZONE" \
    --format='value(networkInterfaces[0].accessConfigs[0].natIP)')
  [ -n "$VM_IP" ] || { echo "Instance has no external IP" >&2; exit 1; }
else
  TAG_SPEC_BASE="Key=Project,Value=ubicloud-bench Key=BenchName,Value=$VM_NAME"
  tag_spec() {
    local rt="$1"; shift
    local tags="$TAG_SPEC_BASE"
    while [ $# -gt 0 ]; do tags="$tags $1"; shift; done
    echo "ResourceType=$rt,Tags=[$(echo "$tags" | awk '{for(i=1;i<=NF;i++)printf "{%s}%s",$i,(i<NF?",":"")}')]"
  }

  # --- 3. Resolve AZ ID -> AZ name ---
  AZ_NAME=$(aws ec2 describe-availability-zones --region "$REGION" \
    --filters "Name=zone-id,Values=$AZ_ID" \
    --query 'AvailabilityZones[0].ZoneName' --output text)
  [ "$AZ_NAME" != "None" ] || { echo "Could not resolve AZ ID $AZ_ID in $REGION" >&2; exit 1; }
  echo "az_name:        $AZ_NAME"

  # --- 4. Resolve Ubuntu 26.04 amd64 AMI (pinned: HammerDB upstream is x86_64-only) ---
  INSTANCE_ARCH=$(aws ec2 describe-instance-types --region "$REGION" \
    --instance-types "$VM_SIZE" \
    --query 'InstanceTypes[0].ProcessorInfo.SupportedArchitectures[0]' --output text)
  if [ "$INSTANCE_ARCH" != "x86_64" ]; then
    echo "ERROR: requested $VM_SIZE is $INSTANCE_ARCH; bench framework requires amd64 (HammerDB upstream is x86_64-only). Pick an amd64 instance type (e.g., m6id.* m7i.* m8i.*)." >&2
    exit 1
  fi
  AMI_ID=$(aws ssm get-parameter --region "$REGION" \
    --name "/aws/service/canonical/ubuntu/server/26.04/stable/current/amd64/hvm/ebs-gp3/ami-id" \
    --query "Parameter.Value" --output text)
  echo "ami:            $AMI_ID  (amd64, pinned for HammerDB compatibility)"

  # --- 5. SSH keypair (generate locally, import to EC2) ---
  # Idempotent against re-runs with the same --name: any prior keypair with
  # this name is deleted before import (private key never leaves the dev
  # container, so the AWS-side keypair is recreatable trivially).
  [ -f "$KEY_FILE" ] || ssh-keygen -t ed25519 -N "" -C "$VM_NAME" -f "$KEY_FILE" >/dev/null
  aws ec2 delete-key-pair --region "$REGION" --key-name "$VM_NAME" 2>/dev/null || true
  aws ec2 import-key-pair --region "$REGION" --key-name "$VM_NAME" \
    --public-key-material "fileb://${KEY_FILE}.pub" \
    --tag-specifications "$(tag_spec key-pair)" >/dev/null

  # --- 6. VPC + IGW + subnet + RTB + SG with SSH ingress ---
  echo "Creating VPC 10.99.0.0/16..."
  VPC_ID=$(aws ec2 create-vpc --region "$REGION" --cidr-block 10.99.0.0/16 \
    --tag-specifications "$(tag_spec vpc)" \
    --query Vpc.VpcId --output text)
  aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-hostnames

  IGW_ID=$(aws ec2 create-internet-gateway --region "$REGION" \
    --tag-specifications "$(tag_spec internet-gateway)" \
    --query InternetGateway.InternetGatewayId --output text)
  aws ec2 attach-internet-gateway --region "$REGION" --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID"

  SUBNET_ID=$(aws ec2 create-subnet --region "$REGION" --vpc-id "$VPC_ID" \
    --availability-zone "$AZ_NAME" --cidr-block 10.99.1.0/24 \
    --tag-specifications "$(tag_spec subnet)" \
    --query Subnet.SubnetId --output text)
  aws ec2 modify-subnet-attribute --region "$REGION" --subnet-id "$SUBNET_ID" --map-public-ip-on-launch

  RTB_ID=$(aws ec2 create-route-table --region "$REGION" --vpc-id "$VPC_ID" \
    --tag-specifications "$(tag_spec route-table)" \
    --query RouteTable.RouteTableId --output text)
  aws ec2 create-route --region "$REGION" --route-table-id "$RTB_ID" \
    --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
  aws ec2 associate-route-table --region "$REGION" --route-table-id "$RTB_ID" --subnet-id "$SUBNET_ID" >/dev/null

  SG_ID=$(aws ec2 create-security-group --region "$REGION" --vpc-id "$VPC_ID" \
    --group-name "$VM_NAME-sg" --description "Bench client SG for $VM_NAME" \
    --tag-specifications "$(tag_spec security-group)" \
    --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" \
    --protocol tcp --port 22 --cidr "$SSH_CIDR" >/dev/null
  echo "VPC=$VPC_ID  IGW=$IGW_ID  SUBNET=$SUBNET_ID  RTB=$RTB_ID  SG=$SG_ID (port 22 from $SSH_CIDR)"

  # --- 7. Launch EC2 instance ---
  echo "Launching $VM_SIZE in $AZ_NAME..."
  INSTANCE_ID=$(aws ec2 run-instances --region "$REGION" \
    --image-id "$AMI_ID" --instance-type "$VM_SIZE" \
    --key-name "$VM_NAME" --security-group-ids "$SG_ID" --subnet-id "$SUBNET_ID" \
    --tag-specifications "$(tag_spec instance Key=Name,Value=$VM_NAME)" \
    --query 'Instances[0].InstanceId' --output text)
  echo "Instance: $INSTANCE_ID"

  "$SCRIPT_DIR/wait_for_vm_state.sh" "$INSTANCE_ID" running 600 "$REGION"

  VM_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  [ "$VM_IP" != "None" ] || { echo "Instance has no public IP" >&2; exit 1; }
  VM_USER="ubuntu"
fi

# --- 8. Persist metadata ---
# The keys read by bench-run/tail/fetch/ssh-vm (VM_NAME, VM_IP, VM_USER,
# KEY_FILE, PG_*) are identical for both providers, which is why those four
# scripts need no provider awareness at all. Only the teardown-specific keys
# differ.
{
  cat <<META
VM_NAME="$VM_NAME"
PG_RESOURCE="$PG_NAME"
PG_LOCATION="$PG_LOCATION"
PG_PROVIDER="$PG_PROVIDER"
REGION="$REGION"
AZ_ID="$AZ_ID"
INSTANCE_ID="$INSTANCE_ID"
KEY_NAME="$VM_NAME"
KEY_FILE="$KEY_FILE"
VM_IP="$VM_IP"
VM_USER="$VM_USER"
SSH_CIDR="$SSH_CIDR"
META
  if [ "$PG_PROVIDER" = "gcp" ]; then
    cat <<META
GCP_PROJECT_ID="$GCP_PROJECT_ID"
GCP_ZONE="$GCP_ZONE"
GCP_NETWORK="$GCP_NETWORK"
GCP_SUBNET="$GCP_SUBNET"
GCP_FW_RULE="$GCP_FW_RULE"
META
  else
    cat <<META
AZ_NAME="$AZ_NAME"
VPC_ID="$VPC_ID"
IGW_ID="$IGW_ID"
SUBNET_ID="$SUBNET_ID"
RTB_ID="$RTB_ID"
SG_ID="$SG_ID"
META
  fi
} >"$META_FILE"
chmod 600 "$META_FILE"

# --- 9. Open PG firewall rule for this client's public IP ---
FW_DESC="bench-$VM_NAME"
"$INVOKE" POST "/project/default/location/$PG_LOCATION/postgres/$PG_NAME/firewall-rule" \
  -d "{\"cidr\":\"$VM_IP/32\",\"description\":\"$FW_DESC\"}" >/dev/null
echo "PG firewall rule opened for $VM_IP/32 (description=$FW_DESC)"
echo "PG_FIREWALL_RULE_DESC=\"$FW_DESC\"" >>"$META_FILE"

# --- 10. Wait for SSH ---
SSH_OPTS=(-i "$KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
echo "Waiting for SSH on $VM_IP..."
for _ in $(seq 1 60); do
  if ssh "${SSH_OPTS[@]}" "${VM_USER}@${VM_IP}" true 2>/dev/null; then
    echo "SSH up."
    break
  fi
  sleep 5
done

# --- 11. Build payload tarball, scp to VM, run setup.sh ---
sh_quote() {
  local s="$1"
  s="${s//\'/\'\"\'\"\'}"
  printf "'%s'" "$s"
}

TMP_PAYLOAD=$(mktemp -d)
trap 'rm -rf "$TMP_PAYLOAD"' EXIT
mkdir -p "$TMP_PAYLOAD/hammerdb"
{
  printf 'PG_HOST=%s\n'           "$(sh_quote "$PG_IP")"
  printf 'PG_PORT=%s\n'           "$(sh_quote "5432")"
  printf 'PG_USER=%s\n'           "$(sh_quote "postgres")"
  printf 'PG_PASS=%s\n'           "$(sh_quote "$PG_PWD")"
  printf 'PG_DEFAULT_DBASE=%s\n'  "$(sh_quote "postgres")"
  printf 'PG_DBASE=%s\n'          "$(sh_quote "postgres")"
  printf 'PG_SSLMODE=%s\n'        "$(sh_quote "require")"
} >"$TMP_PAYLOAD/bench.env"
cp "$PAYLOADS_DIR/run-pgbench.sh"       "$TMP_PAYLOAD/run-pgbench.sh"
cp "$PAYLOADS_DIR/run-hammerdb-tpcc.sh" "$TMP_PAYLOAD/run-hammerdb-tpcc.sh"
cp "$PAYLOADS_DIR/setup.sh"             "$TMP_PAYLOAD/setup.sh"
cp "$PAYLOADS_DIR/hammerdb/build.tcl"   "$TMP_PAYLOAD/hammerdb/build.tcl"
cp "$PAYLOADS_DIR/hammerdb/run.tcl"     "$TMP_PAYLOAD/hammerdb/run.tcl"

echo "Copying payloads to VM..."
ssh "${SSH_OPTS[@]}" "${VM_USER}@${VM_IP}" 'rm -rf /tmp/bench-payloads && mkdir -p /tmp/bench-payloads/hammerdb'
scp "${SSH_OPTS[@]}" -r "$TMP_PAYLOAD"/* "${VM_USER}@${VM_IP}:/tmp/bench-payloads/"

echo "Running setup.sh on VM (sudo)..."
ssh "${SSH_OPTS[@]}" "${VM_USER}@${VM_IP}" \
  "sudo PAYLOAD_DIR=/tmp/bench-payloads TARGET_USER=$VM_USER HAMMERDB_IMAGE=$HAMMERDB_IMAGE bash /tmp/bench-payloads/setup.sh"

cat <<HINT

=== Done ===
VM:        $VM_NAME  ($VM_IP)  size=$VM_SIZE  placement=$AZ_ID
Target PG: $PG_NAME  ($PG_IP)
Metadata:  $META_FILE
SSH key:   $KEY_FILE
SSH ingr:  $SSH_CIDR

Useful follow-ups:
  $SCRIPT_DIR/bench-run.sh $VM_NAME pgbench -- --init --scale 50 --clients 32 --threads 8 --time 300
  $SCRIPT_DIR/bench-run.sh $VM_NAME tpcc --   --build --run --warehouses 100 --vu 16 --rampup 2 --duration 10
  $SCRIPT_DIR/ssh-vm.sh    $VM_NAME
  $SCRIPT_DIR/bench-tail.sh $VM_NAME
  $SCRIPT_DIR/bench-fetch.sh $VM_NAME ./results/$VM_NAME
  $SCRIPT_DIR/bench-destroy.sh $VM_NAME
HINT
