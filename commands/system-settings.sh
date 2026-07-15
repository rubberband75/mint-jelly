#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/checklist.sh"
source "$SCRIPT_DIR/lib/system-settings.sh"

usage() {
  cat <<'EOF'
Usage:
  mint-jelly system-settings config
  mint-jelly system-settings list
  mint-jelly system-settings list-remote [--remote NAME] [--source-host HOSTNAME]
  mint-jelly system-settings backup [--remote NAME] [--dry-run]
  mint-jelly system-settings restore [restore options]
EOF
}

array_has() { local wanted="$1" value; shift; for value in "$@"; do [[ "$value" == "$wanted" ]] && return 0; done; return 1; }

configure_settings() {
  local id status
  local_operation_lock_acquire; trap local_operation_lock_release EXIT
  config_initialize_if_missing; config_read
  CHECKLIST_IDS=("${SYSTEM_SETTING_IDS[@]}")
  CHECKLIST_LABELS=(); CHECKLIST_DETAILS=(); CHECKLIST_INITIAL_SELECTED=()
  for id in "${SYSTEM_SETTING_IDS[@]}"; do
    CHECKLIST_LABELS+=("${SYSTEM_SETTING_NAME[$id]}")
    CHECKLIST_DETAILS+=("${SYSTEM_SETTING_CLASS[$id]}")
    if array_has "$id" "${SYSTEM_SETTINGS[@]}"; then CHECKLIST_INITIAL_SELECTED+=(1); else CHECKLIST_INITIAL_SELECTED+=(0); fi
  done
  CHECKLIST_TITLE='Select Cinnamon settings to preserve'
  CHECKLIST_NOTE='Hardware profiles restore automatically only on matching hardware.'
  if checklist_run; then
    SYSTEM_SETTINGS=("${CHECKLIST_RESULT[@]}")
    config_write
    log "Configured ${#SYSTEM_SETTINGS[@]} system-settings profile(s)."
  else
    status=$?; (( status == 1 )) || return "$status"
    log 'System-settings configuration unchanged.'
  fi
}

action="${1-}"; [[ -z "$action" ]] || shift
case "$action" in
  config) [[ $# -eq 0 ]] || die 'system-settings config does not accept arguments.'; configure_settings ;;
  list)
    [[ $# -eq 0 ]] || die 'system-settings list does not accept arguments.'
    [[ -f "$MINT_JELLY_CONFIG_FILE" ]] || { printf 'No system settings configured.\n'; exit 0; }
    config_read
    for id in "${SYSTEM_SETTINGS[@]}"; do printf '%s\t%s\t%s\n' "$id" "${SYSTEM_SETTING_CLASS[$id]}" "${SYSTEM_SETTING_NAME[$id]}"; done
    ;;
  backup) MINT_JELLY_COMMAND='mint-jelly system-settings backup' exec "$SCRIPT_DIR/backup.sh" --domain system-settings "$@" ;;
  restore) MINT_JELLY_COMMAND='mint-jelly system-settings restore' exec "$SCRIPT_DIR/restore.sh" --domain system-settings "$@" ;;
  list-remote) MINT_JELLY_COMMAND='mint-jelly system-settings list-remote' exec "$SCRIPT_DIR/restore.sh" --domain system-settings --list "$@" ;;
  -h|--help|'') usage ;;
  *) die "Unknown system-settings command: $action" ;;
esac
