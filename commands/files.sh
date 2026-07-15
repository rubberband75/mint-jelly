#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/config.sh"

usage() {
  cat <<'EOF'
Usage:
  mint-jelly files config
  mint-jelly files add PATH...
  mint-jelly files remove PATH...
  mint-jelly files list
  mint-jelly files list-remote [--remote NAME] [--source-host HOSTNAME]
  mint-jelly files backup [--remote NAME] [--dry-run]
  mint-jelly files restore [restore options]
EOF
}

normalize_path() {
  local path="$1"
  [[ "$path" == '~/'* ]] && path="$HOME/${path:2}"
  [[ "$path" == /* ]] || path="$(realpath -m -- "$path")"
  validate_absolute_path "$path" || die "Unsafe file path: $1"
  if [[ "$path" == "$HOME/"* ]]; then printf '~/%s' "${path#"$HOME/"}"; else printf '%s' "$path"; fi
}

array_has() {
  local wanted="$1" value; shift
  for value in "$@"; do [[ "$value" == "$wanted" ]] && return 0; done
  return 1
}

action="${1-}"; [[ -z "$action" ]] || shift
case "$action" in
  add|remove)
    (( $# > 0 )) || die "files $action requires at least one path."
    local_operation_lock_acquire; trap local_operation_lock_release EXIT
    config_initialize_if_missing; config_read
    changed='false'
    if [[ "$action" == add ]]; then
      for value in "$@"; do
        value="$(normalize_path "$value")"
        if ! array_has "$value" "${FILE_SPECS[@]}"; then FILE_SPECS+=("$value"); changed='true'; fi
      done
    else
      retained=()
      for existing in "${FILE_SPECS[@]}"; do
        keep='true'
        for value in "$@"; do [[ "$existing" == "$(normalize_path "$value")" ]] && keep='false'; done
        [[ "$keep" == true ]] && retained+=("$existing") || changed='true'
      done
      FILE_SPECS=("${retained[@]}")
    fi
    [[ "$changed" == false ]] || config_write
    log "Configured file paths: ${#FILE_SPECS[@]}"
    ;;
  list)
    [[ $# -eq 0 ]] || die 'files list does not accept arguments.'
    [[ -f "$MINT_JELLY_CONFIG_FILE" ]] || { printf 'No file paths configured.\n'; exit 0; }
    config_read
    (( ${#FILE_SPECS[@]} )) && printf '%s\n' "${FILE_SPECS[@]}" || printf 'No file paths configured.\n'
    ;;
  config)
    [[ $# -eq 0 ]] || die 'files config does not accept arguments.'
    config_initialize_if_missing
    printf 'Configured file paths:\n'
    "$SCRIPT_DIR/mint-jelly" files list
    printf '\nUse "mint-jelly files add PATH" and "mint-jelly files remove PATH" to change this list.\n'
    ;;
  backup) MINT_JELLY_COMMAND='mint-jelly files backup' exec "$SCRIPT_DIR/backup.sh" --domain files "$@" ;;
  restore) MINT_JELLY_COMMAND='mint-jelly files restore' exec "$SCRIPT_DIR/restore.sh" --domain files "$@" ;;
  list-remote) MINT_JELLY_COMMAND='mint-jelly files list-remote' exec "$SCRIPT_DIR/restore.sh" --domain files --list "$@" ;;
  -h|--help|'') usage ;;
  *) die "Unknown files command: $action" ;;
esac
