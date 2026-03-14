#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

require_bash_version 4

BUCKET_NAME=""
REGION="us-east-1"
PROFILE=""
STATE_PREFIX="terraform-import"
WRITE_CONFIG=0
BACKEND_CONFIG_PATH="config/backend-config.json"
DISABLE_VERSIONING=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage:
  scripts/create-remote-backend.sh --bucket <name> [options]

Options:
  --bucket <name>              S3 bucket for Terraform state (required)
  --region <name>              AWS region (default: us-east-1)
  --profile <name>             AWS profile (optional)
  --state-prefix <prefix>      Prefix for Terraform state keys (default: terraform-import)
  --write-config               Write config/backend-config.json
  --backend-config <path>      Backend config output path (default: config/backend-config.json)
  --disable-versioning         Do not enable S3 versioning
  --dry-run                    Print commands without executing
  -h, --help                   Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket)
      BUCKET_NAME="${2:-}"
      shift 2
      ;;
    --region)
      REGION="${2:-}"
      shift 2
      ;;
    --profile)
      PROFILE="${2:-}"
      shift 2
      ;;
    --state-prefix)
      STATE_PREFIX="${2:-}"
      shift 2
      ;;
    --write-config)
      WRITE_CONFIG=1
      shift
      ;;
    --backend-config)
      BACKEND_CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --disable-versioning)
      DISABLE_VERSIONING=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$BUCKET_NAME" ]] || die "--bucket is required"

require_cmd aws

aws_base=(aws --region "$REGION")
if [[ -n "$PROFILE" ]]; then
  aws_base+=(--profile "$PROFILE")
fi

aws_run() {
  run_cmd "${aws_base[@]}" "$@"
}

bucket_exists=0

if [[ "$DRY_RUN" -ne 1 ]]; then
  if "${aws_base[@]}" s3api head-bucket --bucket "$BUCKET_NAME" >/dev/null 2>&1; then
    bucket_exists=1
  fi
else
  warn "Dry-run enabled: resource existence checks are skipped."
fi

if [[ "$bucket_exists" -eq 0 ]]; then
  if [[ "$REGION" == "us-east-1" ]]; then
    aws_run s3api create-bucket --bucket "$BUCKET_NAME"
  else
    aws_run s3api create-bucket \
      --bucket "$BUCKET_NAME" \
      --create-bucket-configuration "LocationConstraint=${REGION}"
  fi
else
  log "S3 bucket already exists: $BUCKET_NAME"
fi

if [[ "$DISABLE_VERSIONING" -ne 1 ]]; then
  aws_run s3api put-bucket-versioning \
    --bucket "$BUCKET_NAME" \
    --versioning-configuration Status=Enabled
fi

aws_run s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration '{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":true}'

aws_run s3api put-bucket-encryption \
  --bucket "$BUCKET_NAME" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

if [[ "$WRITE_CONFIG" -eq 1 ]]; then
  backend_file="$(resolve_path "$BACKEND_CONFIG_PATH")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log ">> would write backend config: $backend_file"
  else
    mkdir -p "$(dirname "$backend_file")"
    cat >"$backend_file" <<EOF
{
  "bucket": "${BUCKET_NAME}",
  "region": "${REGION}",
  "useLockfile": true,
  "encrypt": true,
  "profile": "${PROFILE}",
  "stateKeyPrefix": "${STATE_PREFIX}",
  "kmsKeyId": ""
}
EOF
    log "Backend config written to: $backend_file"
  fi
fi

log "Remote backend setup complete (S3 state + S3 lockfile)."
