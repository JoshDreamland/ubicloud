---
name: ubicloud-pg-ami
description: Trigger a postgres-vm-images AMI build and update the devcontainer's pg_aws_ami so the new image can be used in local PG provisioning. Use when iterating on AMI-baked changes (compress script, systemd units, setup_base.sh) that need testing against a fresh VM.
user-invocable: true
---

# ubicloud-pg-ami skill

End-to-end helper: triggers a postgres-vm-images AMI build via GitHub Actions, waits for completion, extracts AMI IDs from job logs, and updates the local `pg_aws_ami` table so any subsequent `POST /postgres/<name>` provisions from the new image.

## Why a skill

`postgres-vm-image.yml` has 14 inputs and three are subtly tricky for *devcontainer-usable* test AMIs. Getting them wrong costs ~35 min of CI per attempt:

- `aws_ami_regions` must include account `248825820370` (the devcontainer's assumed-role account) AND list `us-west-2` as a copy destination — otherwise the source AMI ends up encrypted with the default EBS key and cannot be cross-account shared
- `use_aws_role=true` is required, else GuardDuty's S3 download in `build.sh` 403s
- `install_guardduty=false`, `clamscan_enabled=false`, `install_wiz=false` match what production main builds use

This skill bakes those in.

## Usage

```bash
.devcontainer/scripts/build-and-rollout-pg-ami.sh --suffix 20260528.0.4
```

Options:
- `--branch <ref>` — postgres-vm-images branch (default: `andreyc/pg-log-compress`, left over from the log-rotation work; override it)
- `--suffix <YYYYMMDD.X.Y>` — required unless `--rollout-only`; must be unique across past builds
- `--prefix <name>` — image_prefix (default: `pg-log-test`; likewise override it)
- `--rollout-only <run-id>` — skip the build entirely and roll out an existing successful run
- `--no-wait` — return after triggering, skip the watch+rollout
- `--no-apply` — skip the `pg_aws_ami` update (just print extracted AMI IDs)

The script blocks for ~50-60 min while watching the build. Use `--no-wait` if you want to walk away, then finish with `--rollout-only <run-id>`.

## What it does

1. Triggers `postgres-vm-image.yml` via `gh workflow run` with prod-matching share config (5 regions, each shared with both 248825820370 and 176778311874).
2. Finds its own run by matching the image suffix against the build job names, so a scheduled build starting at the same moment is not mistaken for ours.
3. Polls the run to completion, tolerating ~10 min of API flakiness. Only a `completed` status with a non-success conclusion counts as a build failure; if the API stays unreachable the script exits 2 and prints the `--rollout-only` command to resume with.
4. On success, greps each build job's log for `Registered AMI:` (source us-west-2) and `Copied AMI to <region>:` (other 4 regions) to collect all 10 region+arch AMI IDs.
5. Updates `pg_aws_ami` rows in the dev DB, matching by `(aws_location_name, arch)` — same pattern as `register-pg-region.sh`. All postgres versions (16/17/18) sharing one AMI get updated together.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | build succeeded and (unless `--no-apply`) `pg_aws_ami` was updated |
| 1 | the build itself failed, or a precondition was wrong |
| 2 | outcome unknown — the API was unreachable while watching. The build is probably still running; resume with `--rollout-only <run-id>` rather than rebuilding. |

The script does NOT generate a migration file. For PR prep use `.devcontainer/scripts/update-pg-ami-refs.rb --apply` instead.

## Behavior guidelines

- If the build fails, the script does NOT touch `pg_aws_ami` (exits non-zero before reaching the apply step).
- Existing PG VMs continue running on whatever AMI they were launched from; only newly-provisioned servers pick up the new AMI.
- `pg_aws_ami` may get reverted by `prepare-pg-ubicloud.sh` or `register-pg-region.sh` (both fetch latest main-branch AMIs). Re-run this skill if that happens.
- For incremental script-only changes you want to test without a 35-min rebuild, `scp` the updated file directly onto a running VM and `systemctl restart` the relevant unit — that's what we did for the json-aware compressor before the AMI baked it in.

## Inputs baked in

| Workflow input | Value | Why |
|---|---|---|
| `image_resize_gb` | 10 | matches prod |
| `build_arm64` | true | devcontainer default size m8gd.large is arm64 |
| `upload_aws_ami` | true | required for the AMI to land in AWS |
| `aws_ami_regions` | 5 regions × 2 accounts | source us-west-2 must be re-copied with custom KMS; shared with 248825820370 (dev) + 176778311874 (pg-ubicloud-ci) |
| `use_aws_role` | true | required for GuardDuty / S3 ACLs |
| `install_guardduty` | false | matches prod main |
| `clamscan_enabled` | false | matches prod main |
| `install_wiz` | false | requires repo secrets; skip for test builds |
| `upload_image` | false | skip MinIO upload (shared bucket) |
| `upload_r2` | false | skip R2 |
| `create_ubicloud_pr` | false | this skill replaces that automation locally |

## Inspecting state

After rollout, the new AMIs are visible via Ruby:

```ruby
DB[:pg_aws_ami].select(:aws_location_name, :arch, :aws_ami_id).distinct.order(:aws_location_name, :arch).all
```

Or via the AWS CLI (which can confirm the AMI is shared with the dev account):

```bash
AWS_PROFILE=pg-test-postgresqladmindev aws ec2 describe-images \
  --region us-west-2 --image-ids ami-... \
  --query 'Images[].{ID:ImageId,Name:Name,Owner:OwnerId,State:State}'
```
