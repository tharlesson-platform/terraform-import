#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

CONFIG_PATH="config/import-config.json"
BACKEND_CONFIG_PATH="config/backend-config.json"
ONLY_MODULES=""
SETUP_BACKEND=0
CONTINUE_ON_ERROR=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage:
  scripts/import-all.sh [options]

Options:
  --config <path>              Import config path (default: config/import-config.json)
  --backend-config <path>      Backend config path (default: config/backend-config.json)
  --only <csv>                 Comma-separated module list (example: vpc,eks,rds)
  --setup-backend              Configure S3 backend after each import
  --continue-on-error          Continue processing other modules on failure
  --dry-run                    Print commands without executing
  -h, --help                   Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --backend-config)
      BACKEND_CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --only)
      ONLY_MODULES="${2:-}"
      shift 2
      ;;
    --setup-backend)
      SETUP_BACKEND=1
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

require_cmd jq

CONFIG_FILE="$(resolve_path "$CONFIG_PATH")"
[[ -f "$CONFIG_FILE" ]] || die "Import config not found: $CONFIG_FILE"

mapfile -t selected_modules < <(jq -r '.modules[] | select(.enabled == true) | .name' "$CONFIG_FILE")
[[ ${#selected_modules[@]} -gt 0 ]] || die "No enabled modules found in config."

if [[ -n "$ONLY_MODULES" ]]; then
  IFS=',' read -r -a requested_modules <<<"$ONLY_MODULES"
  declare -A request_index=()
  for item in "${requested_modules[@]}"; do
    trimmed="${item// /}"
    [[ -n "$trimmed" ]] && request_index["$trimmed"]=1
  done

  filtered_modules=()
  for module_name in "${selected_modules[@]}"; do
    if [[ -n "${request_index[$module_name]:-}" ]]; then
      filtered_modules+=("$module_name")
    fi
  done
  selected_modules=("${filtered_modules[@]}")
fi

[[ ${#selected_modules[@]} -gt 0 ]] || die "No modules selected after filtering."

log "Modules to process: ${selected_modules[*]}"

failed_modules=()
for module_name in "${selected_modules[@]}"; do
  cmd=(
    bash
    "${SCRIPT_DIR}/import-module.sh"
    --module "$module_name"
    --config "$CONFIG_PATH"
    --backend-config "$BACKEND_CONFIG_PATH"
  )

  [[ "$SETUP_BACKEND" -eq 1 ]] && cmd+=(--setup-backend)
  [[ "$DRY_RUN" -eq 1 ]] && cmd+=(--dry-run)

  if ! "${cmd[@]}"; then
    failed_modules+=("$module_name")
    if [[ "$CONTINUE_ON_ERROR" -ne 1 ]]; then
      die "Module '$module_name' failed."
    fi
  fi
done

if [[ ${#failed_modules[@]} -gt 0 ]]; then
  die "Finished with failures: ${failed_modules[*]}"
fi

log "All selected modules completed successfully."
