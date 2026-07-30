#!/bin/bash
# Trigger a postgres-vm-images AMI build and update the dev pg_aws_ami table
# so subsequent PG provisions launch from the new image.
#
# See `.claude/skills/ubicloud-pg-ami/SKILL.md` for the full rationale (why
# the input flags are what they are, and why this lives behind a script).
set -euo pipefail

REPO="ClickHouse/postgres-vm-images"
BRANCH="andreyc/pg-log-compress"
IMAGE_PREFIX="pg-log-test"
IMAGE_SUFFIX=""
WAIT=true
APPLY=true

# Accounts that need launch permission on test AMIs in every region:
#   248825820370 = pg-test  (the devcontainer's assumed role)
#   176778311874 = pg-ubicloud-ci (prod test-host account, conventional)
SHARE_ACCOUNTS="248825820370:176778311874"

usage() {
  cat >&2 <<USAGE
Usage: $0 --suffix YYYYMMDD.X.Y [options]

Required:
  --suffix V         image_suffix (e.g. 20260528.0.4); must be unique

Optional:
  --branch REF       postgres-vm-images branch to build (default: $BRANCH)
  --prefix NAME      image_prefix (default: $IMAGE_PREFIX)
  --no-wait          return after triggering; skip watch+rollout
  --no-apply         skip the pg_aws_ami DB update (just print extracted IDs)
  -h, --help         this message
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --branch) BRANCH="$2"; shift 2 ;;
    --suffix) IMAGE_SUFFIX="$2"; shift 2 ;;
    --prefix) IMAGE_PREFIX="$2"; shift 2 ;;
    --no-wait) WAIT=false; shift ;;
    --no-apply) APPLY=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [ -z "$IMAGE_SUFFIX" ]; then
  echo "ERROR: --suffix required" >&2
  usage
  exit 1
fi

# All 5 regions in pg_aws_ami get copies, each shared with both accounts.
# us-west-2 is in this list (not just the source) so the AMI is re-copied
# with the workflow's custom KMS key — otherwise it uses default EBS
# encryption which is not cross-account shareable.
AWS_AMI_REGIONS="us-west-2:${SHARE_ACCOUNTS},us-east-1:${SHARE_ACCOUNTS},us-east-2:${SHARE_ACCOUNTS},eu-west-1:${SHARE_ACCOUNTS},ap-southeast-2:${SHARE_ACCOUNTS}"

echo "=== Triggering postgres-vm-image.yml on $BRANCH (suffix $IMAGE_SUFFIX) ==="
gh workflow run postgres-vm-image.yml \
  --repo "$REPO" --ref "$BRANCH" \
  -f image_prefix="$IMAGE_PREFIX" \
  -f image_suffix="$IMAGE_SUFFIX" \
  -f image_resize_gb=10 \
  -f build_only=false \
  -f build_arm64=true \
  -f run_apt_upgrade=false \
  -f upload_image=false \
  -f upload_r2=false \
  -f upload_aws_ami=true \
  -f aws_ami_regions="$AWS_AMI_REGIONS" \
  -f create_ubicloud_pr=false \
  -f test_pr_creation=false \
  -f use_aws_role=true \
  -f install_guardduty=false \
  -f clamscan_enabled=false \
  -f install_wiz=false

sleep 4
RUN_ID=$(gh run list --repo "$REPO" --workflow=postgres-vm-image.yml --branch "$BRANCH" --limit 1 --json databaseId -q '.[0].databaseId')
echo "Run ID: $RUN_ID"
echo "URL:    https://github.com/$REPO/actions/runs/$RUN_ID"

if [ "$WAIT" = "false" ]; then
  echo
  echo "Triggered. Skipping wait+rollout per --no-wait."
  echo "When complete, re-run rollout with: $0 --suffix $IMAGE_SUFFIX --branch $BRANCH"
  exit 0
fi

echo
echo "=== Watching run (blocks until done; ~35-45 min) ==="
# gh run watch occasionally dies on transient API errors; retry up to 3x.
attempt=0
while [ $attempt -lt 3 ]; do
  if gh run watch "$RUN_ID" --repo "$REPO" --exit-status; then
    break
  fi
  attempt=$((attempt + 1))
  echo "(watch died; retry $attempt/3 in 10s)"
  sleep 10
done

# Re-check the final status independently of the watcher.
FINAL=$(gh run view "$RUN_ID" --repo "$REPO" --json status,conclusion -q '.status + ":" + .conclusion')
if [ "$FINAL" != "completed:success" ]; then
  echo "ERROR: run did not complete successfully (state: $FINAL)" >&2
  exit 1
fi
echo "Build completed successfully."

echo
echo "=== Extracting AMI IDs from job logs ==="
# Same log-grep pattern that register-pg-region.sh uses. Source us-west-2 AMI
# appears as "Registered AMI: ami-..."; the 4 copies appear as
# "Copied AMI to <region>: ami-...".

declare -A AMIS  # ["region:arch"] => ami-...

for arch in x64 arm64; do
  JOB_ID=$(gh api "repos/$REPO/actions/runs/$RUN_ID/jobs?per_page=50" \
    --jq ".jobs[] | select(.name | test(\"-$arch-\")) | .id" | head -1)
  if [ -z "$JOB_ID" ]; then
    echo "ERROR: no $arch build job in run $RUN_ID" >&2
    exit 1
  fi
  LOG=$(gh api "repos/$REPO/actions/jobs/$JOB_ID/logs" 2>/dev/null)

  SOURCE_AMI=$(echo "$LOG" | grep -oP "Registered AMI: \Kami-[0-9a-f]+" | head -1)
  if [ -n "$SOURCE_AMI" ]; then
    AMIS["us-west-2:$arch"]="$SOURCE_AMI"
  fi

  while read -r line; do
    region=$(echo "$line" | awk -F'[: ]+' '{print $1}')
    ami=$(echo "$line" | grep -oE 'ami-[0-9a-f]+')
    if [ -n "$region" ] && [ -n "$ami" ]; then
      AMIS["$region:$arch"]="$ami"
    fi
  done < <(echo "$LOG" | grep -oP "Copied AMI to \K[a-z0-9-]+: ami-[0-9a-f]+")
done

if [ "${#AMIS[@]}" -eq 0 ]; then
  echo "ERROR: no AMI IDs extracted from logs" >&2
  exit 1
fi

echo "Extracted ${#AMIS[@]} AMI IDs:"
for key in "${!AMIS[@]}"; do
  echo "  ${key}  ${AMIS[$key]}"
done

if [ "$APPLY" = "false" ]; then
  echo
  echo "Skipping pg_aws_ami update per --no-apply."
  exit 0
fi

echo
echo "=== Updating pg_aws_ami in dev DB ==="

# Build a positional arg list for ruby: triplets of (region arch ami).
RB_ARGS=()
for key in "${!AMIS[@]}"; do
  region="${key%:*}"
  arch="${key##*:}"
  RB_ARGS+=("$region" "$arch" "${AMIS[$key]}")
done

# Run from repo root so `-r ./loader` finds it.
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
bundle exec ruby -r ./loader -e '
total = 0
DB.transaction do
  i = 0
  while i < ARGV.length
    region, arch, ami = ARGV[i], ARGV[i+1], ARGV[i+2]
    n = DB[:pg_aws_ami].where(aws_location_name: region, arch: arch).update(aws_ami_id: ami)
    puts "  #{region.ljust(16)} #{arch.ljust(6)} #{ami}  (#{n} rows)"
    total += n
    i += 3
  end
end
puts "Updated #{total} rows total"
' -- "${RB_ARGS[@]}"

echo
echo "Done. Newly-provisioned PG resources in mapped regions will now launch from the new AMIs."
