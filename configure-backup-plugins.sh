#!/usr/bin/env bash
# Interactively configure the backup-discovery plugins saved for recovery.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/backup-plugins.sh
source "$SCRIPT_DIR/lib/backup-plugins.sh"
# shellcheck source=lib/checklist.sh
source "$SCRIPT_DIR/lib/checklist.sh"

usage() {
  printf 'Usage: %s\n' "${MINT_JELLY_COMMAND:-mint-jelly config backup-plugins}"
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
load_backup_plugins

CHECKLIST_IDS=("${BACKUP_PLUGIN_NAMES[@]}")
CHECKLIST_LABELS=("${BACKUP_PLUGIN_NAMES[@]}")
CHECKLIST_DETAILS=()
CHECKLIST_INITIAL_SELECTED=()
for plugin in "${BACKUP_PLUGIN_NAMES[@]}"; do
  CHECKLIST_DETAILS+=('backup discovery and restore hooks')
  if array_contains "$plugin" "${BACKUP_PLUGINS[@]}"; then
    CHECKLIST_INITIAL_SELECTED+=(1)
  else
    CHECKLIST_INITIAL_SELECTED+=(0)
  fi
done
for configured_plugin in "${BACKUP_PLUGINS[@]}"; do
  if ! array_contains "$configured_plugin" "${BACKUP_PLUGIN_NAMES[@]}"; then
    CHECKLIST_IDS+=("$configured_plugin")
    CHECKLIST_LABELS+=("$configured_plugin (unavailable)")
    CHECKLIST_DETAILS+=('[retired or missing; removed when changes are saved]')
    CHECKLIST_INITIAL_SELECTED+=(1)
  fi
done
(( ${#CHECKLIST_IDS[@]} > 0 )) \
  || die "No backup plugins were found in $SCRIPT_DIR/backup-plugins"
CHECKLIST_TITLE='Select backup plugins'
CHECKLIST_NOTE="Unavailable entries are removed when changes are saved. Selections are written to $MINT_JELLY_CONFIG_FILE after confirmation."

if checklist_run; then
  :
else
  status=$?
  (( status == 1 )) || exit "$status"
  log 'Backup-plugin configuration unchanged.'
  exit 0
fi

BACKUP_PLUGINS=()
for plugin in "${CHECKLIST_RESULT[@]}"; do
  if array_contains "$plugin" "${BACKUP_PLUGIN_NAMES[@]}"; then
    BACKUP_PLUGINS+=("$plugin")
  else
    warn "Removing unavailable backup plugin from the configuration: $plugin"
  fi
done
if (( ${#BACKUP_PLUGINS[@]} == 0 && ${#BACKUP_SOURCE_SPECS[@]} == 0 )); then
  die 'At least one available backup source or backup plugin must remain configured.'
fi
config_write
if (( ${#BACKUP_PLUGINS[@]} == 0 )); then
  log "All backup plugins disabled in $MINT_JELLY_CONFIG_FILE"
else
  log "Enabled backup plugins: ${BACKUP_PLUGINS[*]}"
fi
