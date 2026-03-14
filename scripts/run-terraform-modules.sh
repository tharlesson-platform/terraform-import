#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

require_bash_version 4

CONFIG_PATH="config/terraform-modules-config.json"
ACTION="plan"
ONLY_MODULES=""
IMPORT_MAP_PATH="config/import-map.json"
SYNC_BACKEND_FROM_CONFIG=0
BACKEND_CONFIG_PATH="config/backend-config.json"
AUTO_APPROVE=0
CONTINUE_ON_ERROR=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage:
  scripts/run-terraform-modules.sh [options]

Options:
  --config <path>                     Terraform-modules integration config (default: config/terraform-modules-config.json)
  --action <plan|apply|import>        Action to run in each stack (default: plan)
  --only <csv>                        Comma-separated module list (example: vpc,eks,rds)
  --import-map <path>                 Import map file for action=import (default: config/import-map.json)
  --sync-backend-from-config          Rewrite stack backend.hcl from backend-config.json
  --backend-config <path>             Backend config JSON (default: config/backend-config.json)
  --auto-approve                      Use -auto-approve for apply
  --continue-on-error                 Continue processing remaining stacks on error
  --dry-run                           Print commands without executing
  -h, --help                          Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --action)
      ACTION="${2:-}"
      shift 2
      ;;
    --only)
      ONLY_MODULES="${2:-}"
      shift 2
      ;;
    --import-map)
      IMPORT_MAP_PATH="${2:-}"
      shift 2
      ;;
    --sync-backend-from-config)
      SYNC_BACKEND_FROM_CONFIG=1
      shift
      ;;
    --backend-config)
      BACKEND_CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --auto-approve)
      AUTO_APPROVE=1
      shift
      ;;
    --continue-on-error)
      CONTINUE_ON_ERROR=1
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

case "$ACTION" in
  plan | apply | import) ;;
  *)
    die "--action must be one of: plan, apply, import"
    ;;
esac

require_cmd jq
require_cmd terraform

CONFIG_FILE="$(resolve_path "$CONFIG_PATH")"
[[ -f "$CONFIG_FILE" ]] || die "Config not found: $CONFIG_FILE"

tf_modules_path_raw="$(jq -r '.terraformModulesPath // "../terraform-modules"' "$CONFIG_FILE")"
client="$(jq -r '.client // empty' "$CONFIG_FILE")"
environment="$(jq -r '.environment // empty' "$CONFIG_FILE")"

[[ -n "$client" ]] || die "Config is missing 'client'"
[[ -n "$environment" ]] || die "Config is missing 'environment'"

TF_MODULES_ROOT="$(resolve_path "$tf_modules_path_raw")"
LIVE_ROOT="${TF_MODULES_ROOT}/live/${client}/${environment}"
[[ -d "$LIVE_ROOT" ]] || die "Live root not found: $LIVE_ROOT"

if [[ "$ACTION" == "import" ]]; then
  IMPORT_MAP_FILE="$(resolve_path "$IMPORT_MAP_PATH")"
  [[ -f "$IMPORT_MAP_FILE" ]] || die "Import map not found: $IMPORT_MAP_FILE"
fi

if [[ "$SYNC_BACKEND_FROM_CONFIG" -eq 1 ]]; then
  BACKEND_FILE="$(resolve_path "$BACKEND_CONFIG_PATH")"
  [[ -f "$BACKEND_FILE" ]] || die "Backend config not found: $BACKEND_FILE"
fi

mapfile -t requested_modules < <(jq -r '.stackOrder[]?' "$CONFIG_FILE")
if [[ ${#requested_modules[@]} -eq 0 ]]; then
  mapfile -t requested_modules < <(find "$LIVE_ROOT" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort)
fi
[[ ${#requested_modules[@]} -gt 0 ]] || die "No modules/stacks found to process."

if [[ -n "$ONLY_MODULES" ]]; then
  IFS=',' read -r -a only_values <<<"$ONLY_MODULES"
  filtered=()
  declare -A only_index=()
  for item in "${only_values[@]}"; do
    trimmed="${item// /}"
    if [[ -n "$trimmed" && -z "${only_index[$trimmed]:-}" ]]; then
      filtered+=("$trimmed")
      only_index["$trimmed"]=1
    fi
  done

  requested_modules=("${filtered[@]}")
fi

[[ ${#requested_modules[@]} -gt 0 ]] || die "No modules selected after filtering."

declare -A stack_to_modules=()
ordered_stacks=()

for module_name in "${requested_modules[@]}"; do
  stack_name="$(jq -r --arg m "$module_name" '.moduleToStackMap[$m] // $m' "$CONFIG_FILE")"
  if [[ -z "$stack_name" || "$stack_name" == "null" ]]; then
    stack_name="$module_name"
  fi

  if [[ -z "${stack_to_modules[$stack_name]:-}" ]]; then
    ordered_stacks+=("$stack_name")
    stack_to_modules[$stack_name]="$module_name"
  else
    stack_to_modules[$stack_name]="${stack_to_modules[$stack_name]},$module_name"
  fi
done

write_backend_hcl() {
  local stack="$1"
  local stack_dir="$2"
  local state_prefix
  local key
  local bucket
  local region
  local use_lockfile
  local profile
  local kms_key_id
  local encrypt
  local backend_hcl_file

  state_prefix="$(jq -r '.stateKeyPrefix // "terraform-import"' "$BACKEND_FILE")"
  state_prefix="${state_prefix#/}"
  state_prefix="${state_prefix%/}"
  key="${state_prefix}/${client}/${environment}/${stack}/terraform.tfstate"

  bucket="$(jq -r '.bucket // empty' "$BACKEND_FILE")"
  region="$(jq -r '.region // empty' "$BACKEND_FILE")"
  use_lockfile="$(jq -r '.useLockfile // "true"' "$BACKEND_FILE")"
  profile="$(jq -r '.profile // empty' "$BACKEND_FILE")"
  kms_key_id="$(jq -r '.kmsKeyId // empty' "$BACKEND_FILE")"
  encrypt="$(jq -r '.encrypt // empty' "$BACKEND_FILE")"

  [[ -n "$bucket" ]] || die "backend config is missing 'bucket'"
  [[ -n "$region" ]] || die "backend config is missing 'region'"

  backend_hcl_file="${stack_dir}/backend.hcl"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log ">> would write ${backend_hcl_file} with key ${key}"
    return 0
  fi

  {
    printf 'bucket = "%s"\n' "$bucket"
    printf 'key = "%s"\n' "$key"
    printf 'region = "%s"\n' "$region"
    if [[ "$use_lockfile" == "true" || "$use_lockfile" == "false" ]]; then
      printf 'use_lockfile = %s\n' "$use_lockfile"
    fi
    [[ -n "$profile" ]] && printf 'profile = "%s"\n' "$profile"
    [[ -n "$kms_key_id" ]] && printf 'kms_key_id = "%s"\n' "$kms_key_id"
    if [[ "$encrypt" == "true" || "$encrypt" == "false" ]]; then
      printf 'encrypt = %s\n' "$encrypt"
    fi
  } >"$backend_hcl_file"
}

run_stack() {
  local stack="$1"
  local stack_dir="$2"
  local related_modules_csv="$3"
  local init_cmd
  local plan_cmd
  local apply_cmd

  if [[ "$SYNC_BACKEND_FROM_CONFIG" -eq 1 ]]; then
    write_backend_hcl "$stack" "$stack_dir"
  fi

  if [[ -f "${stack_dir}/backend.hcl" ]]; then
    init_cmd=(terraform "-chdir=${stack_dir}" init -reconfigure -backend-config=backend.hcl)
  else
    init_cmd=(terraform "-chdir=${stack_dir}" init -reconfigure)
  fi
  run_cmd "${init_cmd[@]}"

  plan_cmd=(terraform "-chdir=${stack_dir}" plan)
  if [[ -f "${stack_dir}/terraform.tfvars" ]]; then
    plan_cmd+=(-var-file=terraform.tfvars)
  fi

  case "$ACTION" in
    plan)
      run_cmd "${plan_cmd[@]}"
      ;;
    apply)
      apply_cmd=(terraform "-chdir=${stack_dir}" apply)
      if [[ -f "${stack_dir}/terraform.tfvars" ]]; then
        apply_cmd+=(-var-file=terraform.tfvars)
      fi
      [[ "$AUTO_APPROVE" -eq 1 ]] && apply_cmd+=(-auto-approve)
      run_cmd "${apply_cmd[@]}"
      ;;
    import)
      IFS=',' read -r -a related_modules <<<"$related_modules_csv"
      for module_key in "${related_modules[@]}"; do
        mapfile -t import_entries < <(jq -c --arg m "$module_key" '.imports[$m][]?' "$IMPORT_MAP_FILE")
        if [[ ${#import_entries[@]} -eq 0 ]]; then
          warn "No import entries for module '${module_key}' in ${IMPORT_MAP_FILE}"
          continue
        fi

        for entry in "${import_entries[@]}"; do
          address="$(jq -r '.address // empty' <<<"$entry")"
          id_value="$(jq -r '.id // empty' <<<"$entry")"
          [[ -n "$address" ]] || die "Import entry for module '${module_key}' has empty 'address'"
          [[ -n "$id_value" ]] || die "Import entry for module '${module_key}' has empty 'id'"
          run_cmd terraform "-chdir=${stack_dir}" import "$address" "$id_value"
        done
      done

      run_cmd "${plan_cmd[@]}"
      ;;
    *)
      die "Unsupported action: $ACTION"
      ;;
  esac
}

failed_stacks=()
for stack_name in "${ordered_stacks[@]}"; do
  stack_dir="${LIVE_ROOT}/${stack_name}"
  related_modules_csv="${stack_to_modules[$stack_name]}"

  if [[ ! -d "$stack_dir" ]]; then
    warn "Stack directory not found, skipping: $stack_dir"
    continue
  fi

  log "Processing stack '${stack_name}' from modules '${related_modules_csv}'"
  if ! run_stack "$stack_name" "$stack_dir" "$related_modules_csv"; then
    failed_stacks+=("$stack_name")
    if [[ "$CONTINUE_ON_ERROR" -ne 1 ]]; then
      die "Stack '${stack_name}' failed."
    fi
  fi
done

if [[ ${#failed_stacks[@]} -gt 0 ]]; then
  die "Finished with failures: ${failed_stacks[*]}"
fi

log "Completed action '${ACTION}' successfully."
