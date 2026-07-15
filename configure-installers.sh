#!/usr/bin/env bash
# Interactively select bundled software installers for future recovery.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/installers.sh
source "$SCRIPT_DIR/lib/installers.sh"
# shellcheck source=lib/checklist.sh
source "$SCRIPT_DIR/lib/checklist.sh"

usage() {
  printf 'Usage: %s\n' "${MINT_JELLY_COMMAND:-mint-jelly config installers}"
}

array_contains() {
  local expected="$1"
  local value

  shift
  for value in "$@"; do
    [[ "$value" == "$expected" ]] && return 0
  done
  return 1
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    -h|--help)
      [[ $# -eq 1 ]] || die '--help does not accept additional arguments.'
      usage
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
fi

require_initialized_config
config_read
load_installers

CHECKLIST_IDS=("${INSTALLER_NAMES[@]}")
CHECKLIST_LABELS=()
CHECKLIST_DETAILS=()
CHECKLIST_INITIAL_SELECTED=()
for installer in "${INSTALLER_NAMES[@]}"; do
  CHECKLIST_LABELS+=("${INSTALLER_DISPLAY_NAME[$installer]} ($installer)")
  detail="${INSTALLER_DESCRIPTION[$installer]}"
  check_status=0
  if "${INSTALLER_RUN_SCRIPT[$installer]}" check >/dev/null 2>&1; then
    detail+=' [installed]'
  else
    check_status=$?
    if (( check_status > 1 )); then
      detail+=' [installation status unavailable]'
    fi
  fi
  if array_contains "$installer" "${INSTALLERS[@]}"; then
    detail+=' [configured]'
    CHECKLIST_INITIAL_SELECTED+=(1)
  else
    CHECKLIST_INITIAL_SELECTED+=(0)
  fi
  CHECKLIST_DETAILS+=("$detail")
done
for configured_installer in "${INSTALLERS[@]}"; do
  if ! array_contains "$configured_installer" "${INSTALLER_NAMES[@]}"; then
    CHECKLIST_IDS+=("$configured_installer")
    CHECKLIST_LABELS+=("$configured_installer (unavailable)")
    CHECKLIST_DETAILS+=('[retired or missing; removed when changes are saved]')
    CHECKLIST_INITIAL_SELECTED+=(1)
  fi
done
(( ${#CHECKLIST_IDS[@]} > 0 )) \
  || die "No installers were found in $SCRIPT_DIR/installers"
CHECKLIST_TITLE='Select software installers'
CHECKLIST_NOTE="Installed applications remain selectable. Unavailable entries are removed when changes are saved to $MINT_JELLY_CONFIG_FILE."

if checklist_run; then
  :
else
  status=$?
  (( status == 1 )) || exit "$status"
  log 'Installer configuration unchanged.'
  exit 0
fi

INSTALLERS=()
for installer in "${CHECKLIST_RESULT[@]}"; do
  if array_contains "$installer" "${INSTALLER_NAMES[@]}"; then
    INSTALLERS+=("$installer")
  else
    warn "Removing unavailable software installer from the configuration: $installer"
  fi
done
config_write
if (( ${#INSTALLERS[@]} == 0 )); then
  log "All software installers disabled in $MINT_JELLY_CONFIG_FILE"
else
  log "Enabled software installers: ${INSTALLERS[*]}"
fi
