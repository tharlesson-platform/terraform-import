#!/usr/bin/env bash
set -euo pipefail

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${COMMON_DIR}/.." && pwd)"

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
}

require_bash_version() {
  local min_major="${1:-4}"
  local current_major="${BASH_VERSINFO[0]:-0}"

  if (( current_major < min_major )); then
    die "Bash ${min_major}+ is required. Current version: ${BASH_VERSION}"
  fi
}

resolve_path() {
  local path_value="$1"
  if [[ "$path_value" == "~" ]]; then
    printf '%s\n' "$HOME"
  elif [[ "$path_value" == "~/"* ]]; then
    printf '%s/%s\n' "$HOME" "${path_value#~/}"
  elif [[ "$path_value" = /* ]]; then
    printf '%s\n' "$path_value"
  else
    printf '%s/%s\n' "$PROJECT_ROOT" "$path_value"
  fi
}

run_cmd() {
  printf '>>'
  printf ' %q' "$@"
  printf '\n'

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    return 0
  fi

  "$@"
}

ensure_backend_block() {
  local terraform_dir="$1"
  local backend_file="${terraform_dir}/backend.tf"

  if [[ -f "$backend_file" ]]; then
    return 0
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log ">> create ${backend_file} (terraform backend s3 block)"
    return 0
  fi

  cat >"$backend_file" <<'EOF'
terraform {
  backend "s3" {}
}
EOF

  log "Created backend block: $backend_file"
}

terraform_dirs() {
  local root_path="$1"
  [[ -d "$root_path" ]] || return 0

  find "$root_path" \
    -type f \
    -name '*.tf' \
    ! -path '*/.terraform/*' \
    -exec dirname {} \; | sort -u
}

relative_segment() {
  local base_path="$1"
  local current_path="$2"
  local segment=""

  if [[ "$current_path" == "$base_path" ]]; then
    printf 'root\n'
    return 0
  fi

  segment="${current_path#"$base_path"/}"
  segment="${segment#/}"
  segment="${segment%/}"

  if [[ -z "$segment" ]]; then
    printf 'root\n'
    return 0
  fi

  printf '%s\n' "$segment"
}

create_backend_temp_config() {
  local backend_json="$1"
  local state_key="$2"
  local tmp_file
  local bucket
  local region
  local dynamodb_table
  local encrypt
  local profile
  local kms_key_id

  bucket="$(jq -r '.bucket // empty' "$backend_json")"
  region="$(jq -r '.region // empty' "$backend_json")"
  dynamodb_table="$(jq -r '.dynamodbTable // empty' "$backend_json")"
  encrypt="$(jq -r '.encrypt // empty' "$backend_json")"
  profile="$(jq -r '.profile // empty' "$backend_json")"
  kms_key_id="$(jq -r '.kmsKeyId // empty' "$backend_json")"

  [[ -n "$bucket" ]] || die "backend config is missing 'bucket'"
  [[ -n "$region" ]] || die "backend config is missing 'region'"

  tmp_file="$(mktemp)"
  {
    printf 'bucket = "%s"\n' "$bucket"
    printf 'key = "%s"\n' "$state_key"
    printf 'region = "%s"\n' "$region"
    [[ -n "$dynamodb_table" ]] && printf 'dynamodb_table = "%s"\n' "$dynamodb_table"
    if [[ "$encrypt" == "true" || "$encrypt" == "false" ]]; then
      printf 'encrypt = %s\n' "$encrypt"
    fi
    [[ -n "$profile" ]] && printf 'profile = "%s"\n' "$profile"
    [[ -n "$kms_key_id" ]] && printf 'kms_key_id = "%s"\n' "$kms_key_id"
  } >"$tmp_file"

  printf '%s\n' "$tmp_file"
}
