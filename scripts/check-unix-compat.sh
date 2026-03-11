#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

require_bash_version 4

failed=0

check_command() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    log "[OK] command available: $cmd"
  else
    warn "[FAIL] missing command: $cmd"
    failed=1
  fi
}

check_crlf() {
  local file="$1"
  if grep -q $'\r' "$file"; then
    warn "[FAIL] CRLF detected: $file"
    failed=1
  else
    log "[OK] LF line endings: $file"
  fi
}

log "Running Unix compatibility checks..."

check_command bash
check_command make
check_command jq
check_command terraform
check_command terraformer
check_command aws

log "Checking shell syntax..."
if bash -n scripts/common.sh scripts/create-remote-backend.sh scripts/import-module.sh scripts/import-all.sh scripts/run-terraform-modules.sh scripts/check-unix-compat.sh; then
  log "[OK] bash -n passed for all scripts"
else
  warn "[FAIL] bash -n failed"
  failed=1
fi

log "Checking line endings..."
check_crlf Makefile
check_crlf README.md
check_crlf scripts/common.sh
check_crlf scripts/create-remote-backend.sh
check_crlf scripts/import-module.sh
check_crlf scripts/import-all.sh
check_crlf scripts/run-terraform-modules.sh
check_crlf scripts/check-unix-compat.sh

if [[ "$failed" -ne 0 ]]; then
  die "Unix compatibility checks failed."
fi

log "Unix compatibility checks passed."
