#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

MODULE=""
CONFIG_PATH="config/import-config.json"
BACKEND_CONFIG_PATH="config/backend-config.json"
SETUP_BACKEND=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage:
  scripts/import-module.sh --module <name> [options]

Options:
  --module <name>              Module name from config/import-config.json (required)
  --config <path>              Import config path (default: config/import-config.json)
  --backend-config <path>      Backend config path (default: config/backend-config.json)
  --setup-backend              Configure S3 backend after import
  --dry-run                    Print commands without executing
  -h, --help                   Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --module)
      MODULE="${2:-}"
      shift 2
      ;;
    --config)
      CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --backend-config)
      BACKEND_CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --setup-backend)
      SETUP_BACKEND=1
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

[[ -n "$MODULE" ]] || {
  usage
  die "--module is required"
}

require_cmd jq
require_cmd terraformer

CONFIG_FILE="$(resolve_path "$CONFIG_PATH")"
[[ -f "$CONFIG_FILE" ]] || die "Import config not found: $CONFIG_FILE"

if ! jq -e --arg module "$MODULE" '.modules[] | select(.name == $module)' "$CONFIG_FILE" >/dev/null; then
  mapfile -t available_modules < <(jq -r '.modules[].name' "$CONFIG_FILE")
  die "Module '$MODULE' not found. Available modules: ${available_modules[*]}"
fi

mapfile -t resources < <(jq -r --arg module "$MODULE" '.modules[] | select(.name == $module) | .resources[]?' "$CONFIG_FILE")
[[ ${#resources[@]} -gt 0 ]] || die "Module '$MODULE' has no resources configured."

mapfile -t module_regions < <(jq -r --arg module "$MODULE" '.modules[] | select(.name == $module) | .regions[]?' "$CONFIG_FILE")
if [[ ${#module_regions[@]} -gt 0 ]]; then
  regions=("${module_regions[@]}")
else
  mapfile -t regions < <(jq -r '.aws.regions[]?' "$CONFIG_FILE")
  if [[ ${#regions[@]} -eq 0 ]]; then
    fallback_region="$(jq -r '.aws.region // empty' "$CONFIG_FILE")"
    [[ -n "$fallback_region" ]] && regions=("$fallback_region")
  fi
fi

[[ ${#regions[@]} -gt 0 ]] || die "No AWS region configured."

provider="$(jq -r '.terraformer.provider // "aws"' "$CONFIG_FILE")"
base_output="$(jq -r '.terraformer.pathOutput // "terraform/generated"' "$CONFIG_FILE")"
module_output="$(resolve_path "${base_output}/${MODULE}")"
mkdir -p "$module_output"

profile="$(jq -r '.aws.profile // empty' "$CONFIG_FILE")"
mapfile -t filters < <(jq -r --arg module "$MODULE" '.modules[] | select(.name == $module) | .filters[]?' "$CONFIG_FILE")
mapfile -t extra_args < <(jq -r --arg module "$MODULE" '.modules[] | select(.name == $module) | .extraArgs[]?' "$CONFIG_FILE")

resources_csv="$(IFS=,; echo "${resources[*]}")"
regions_csv="$(IFS=,; echo "${regions[*]}")"

terraformer_cmd=(
  terraformer
  import
  "$provider"
  "--resources=${resources_csv}"
  "--regions=${regions_csv}"
  "--path-output=${module_output}"
)

if [[ -n "$profile" ]]; then
  terraformer_cmd+=("--profile=${profile}")
fi

for filter_value in "${filters[@]}"; do
  [[ -n "$filter_value" ]] && terraformer_cmd+=("--filter=${filter_value}")
done

for extra_arg in "${extra_args[@]}"; do
  [[ -n "$extra_arg" ]] && terraformer_cmd+=("$extra_arg")
done

log "Importing module '${MODULE}' into ${module_output}"
run_cmd "${terraformer_cmd[@]}"

if [[ "$SETUP_BACKEND" -ne 1 ]]; then
  log "Module '${MODULE}' imported."
  exit 0
fi

require_cmd terraform

BACKEND_FILE="$(resolve_path "$BACKEND_CONFIG_PATH")"
[[ -f "$BACKEND_FILE" ]] || die "Backend config not found: $BACKEND_FILE"

state_prefix="$(jq -r '.stateKeyPrefix // "terraform-import"' "$BACKEND_FILE")"
state_prefix="${state_prefix#/}"
state_prefix="${state_prefix%/}"

mapfile -t tf_dirs < <(terraform_dirs "$module_output")
if [[ ${#tf_dirs[@]} -eq 0 ]]; then
  warn "No Terraform directories found under: ${module_output}"
  exit 0
fi

for tf_dir in "${tf_dirs[@]}"; do
  ensure_backend_block "$tf_dir"

  segment="$(relative_segment "$module_output" "$tf_dir")"
  if [[ "$segment" == "root" ]]; then
    state_key="${state_prefix}/${MODULE}/terraform.tfstate"
  else
    state_key="${state_prefix}/${MODULE}/${segment}/terraform.tfstate"
  fi

  backend_tmp="$(create_backend_temp_config "$BACKEND_FILE" "$state_key")"
  terraform_cmd=(
    terraform
    "-chdir=${tf_dir}"
    init
    -reconfigure
    -input=false
    "-backend-config=${backend_tmp}"
  )

  if [[ -f "${tf_dir}/terraform.tfstate" ]]; then
    terraform_cmd+=(-migrate-state -force-copy)
  fi

  if ! run_cmd "${terraform_cmd[@]}"; then
    rm -f "$backend_tmp"
    die "terraform init failed for ${tf_dir}"
  fi

  rm -f "$backend_tmp"
done

log "Module '${MODULE}' imported and backend configured."
