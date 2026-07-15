#!/usr/bin/env bash
# Manage Mint Jelly backup remotes and create the initial configuration.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/remote.sh
source "$SCRIPT_DIR/lib/remote.sh"

usage() {
  local command_name="${MINT_JELLY_COMMAND:-mint-jelly config}"

  cat <<EOF
Usage:
  $command_name init
  $command_name remote add
  $command_name remote list
  $command_name remote set-default NAME
  $command_name remote test NAME
  $command_name backup-plugins
  $command_name apt list
  $command_name apt add PACKAGE...
  $command_name apt remove PACKAGE...
  $command_name apt select
  $command_name installers
EOF
}

prompt_value() {
  local variable_name="$1"
  local label="$2"
  local default_value="$3"
  local answer

  printf '%s [%s]: ' "$label" "$default_value"
  IFS= read -r answer
  [[ -n "$answer" ]] || answer="$default_value"
  printf -v "$variable_name" '%s' "$answer"
}

prompt_required() {
  local variable_name="$1"
  local label="$2"
  local answer

  while true; do
    printf '%s: ' "$label"
    IFS= read -r answer
    answer="$(trim "$answer")"
    if [[ -n "$answer" ]]; then
      printf -v "$variable_name" '%s' "$answer"
      return 0
    fi
    warn "$label is required."
  done
}

prompt_yes_no() {
  local label="$1"
  local default_answer="$2"
  local answer suffix

  if [[ "$default_answer" == 'yes' ]]; then
    suffix='Y/n'
  else
    suffix='y/N'
  fi

  while true; do
    printf '%s [%s]: ' "$label" "$suffix"
    IFS= read -r answer
    answer="${answer,,}"
    [[ -n "$answer" ]] || answer="$default_answer"
    case "$answer" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) printf 'Enter yes or no.\n' ;;
    esac
  done
}

add_remote_wizard() {
  local make_default="$1"
  local name type host username port root_path

  is_interactive || die 'Adding a backup remote requires an interactive terminal.'
  printf '\nAdd a backup remote\n'
  while true; do
    prompt_required name 'Unique name'
    if ! validate_safe_name "$name"; then
      warn 'Use letters, digits, periods, underscores, or hyphens.'
    elif remote_exists "$name"; then
      warn "A remote named '$name' already exists."
    else
      break
    fi
  done

  while true; do
    prompt_value type 'Type (ssh/local)' 'ssh'
    type="${type,,}"
    [[ "$type" == 'ssh' || "$type" == 'local' ]] && break
    warn 'Type must be ssh or local.'
  done

  host=''
  username=''
  port='22'
  if [[ "$type" == 'ssh' ]]; then
    prompt_required host 'Hostname'
    prompt_value username 'Username' "$(id -un)"
    prompt_value port 'SSH port' '22'
    prompt_required root_path 'Remote root path'
  else
    prompt_required root_path 'Local root path'
  fi

  config_add_remote_name "$name"
  REMOTE_TYPE["$name"]="$type"
  REMOTE_HOST["$name"]="$host"
  REMOTE_USERNAME["$name"]="$username"
  REMOTE_PORT["$name"]="$port"
  REMOTE_ROOT_PATH["$name"]="$root_path"
  config_validate_remote "$name"

  if [[ "$type" == 'ssh' ]]; then
    printf '\nOpenSSH will now verify the host and prompt for a password if needed.\n'
  fi
  remote_validate_candidate "$name"

  if [[ "$make_default" == 'true' ]]; then
    DEFAULT_REMOTE="$name"
  elif prompt_yes_no "Make '$name' the default remote?" 'no'; then
    DEFAULT_REMOTE="$name"
  fi

  config_write
  log "Saved backup remote '$name' to $MINT_JELLY_CONFIG_FILE"
}

list_remotes() {
  local name marker

  config_read || die "Configuration does not exist: $MINT_JELLY_CONFIG_FILE"
  for name in "${REMOTE_NAMES[@]}"; do
    marker=' '
    [[ "$name" == "$DEFAULT_REMOTE" ]] && marker='*'
    if [[ "${REMOTE_TYPE[$name]}" == 'ssh' ]]; then
      printf '%s %-20s ssh   %s@%s:%s %s\n' \
        "$marker" "$name" "${REMOTE_USERNAME[$name]}" \
        "${REMOTE_HOST[$name]}" "${REMOTE_PORT[$name]}" \
        "${REMOTE_ROOT_PATH[$name]}"
    else
      printf '%s %-20s local %s\n' \
        "$marker" "$name" "${REMOTE_ROOT_PATH[$name]}"
    fi
  done
}

trap remote_close EXIT
require_cmd hostname

if [[ ! -f "$MINT_JELLY_CONFIG_FILE" ]]; then
  case "${1-}" in
    init|-h|--help|'') ;;
    *) require_initialized_config ;;
  esac
fi

case "${1-}" in
  init)
    [[ $# -eq 1 ]] || die 'init does not accept arguments.'
    [[ ! -e "$MINT_JELLY_CONFIG_FILE" ]] \
      || die "Configuration already exists: $MINT_JELLY_CONFIG_FILE"
    config_initialize_defaults
    add_remote_wizard true
    ;;
  remote)
    case "${2-}" in
      add)
        [[ $# -eq 2 ]] || die 'remote add does not accept arguments.'
        config_read
        add_remote_wizard false
        ;;
      list)
        [[ $# -eq 2 ]] || die 'remote list does not accept arguments.'
        list_remotes
        ;;
      set-default)
        [[ $# -eq 3 ]] || die 'remote set-default requires a remote name.'
        config_read || die "Configuration does not exist: $MINT_JELLY_CONFIG_FILE"
        remote_exists "$3" || die "Unknown backup remote: $3"
        DEFAULT_REMOTE="$3"
        config_write
        log "Default backup remote set to '$3'."
        ;;
      test)
        [[ $# -eq 3 ]] || die 'remote test requires a remote name.'
        config_read || die "Configuration does not exist: $MINT_JELLY_CONFIG_FILE"
        remote_exists "$3" || die "Unknown backup remote: $3"
        remote_validate_candidate "$3"
        log "Backup remote '$3' is reachable and writable."
        ;;
      -h|--help|'')
        usage
        ;;
      *)
        die "Unknown remote command: $2"
        ;;
    esac
    ;;
  backup-plugins)
    shift
    MINT_JELLY_COMMAND='mint-jelly config backup-plugins' \
      exec "$SCRIPT_DIR/configure-backup-plugins.sh" "$@"
    ;;
  apt)
    shift
    MINT_JELLY_COMMAND='mint-jelly config apt' \
      exec "$SCRIPT_DIR/configure-apt.sh" "$@"
    ;;
  installers)
    shift
    MINT_JELLY_COMMAND='mint-jelly config installers' \
      exec "$SCRIPT_DIR/configure-installers.sh" "$@"
    ;;
  -h|--help|'')
    usage
    ;;
  *)
    die "Unknown command: $1"
    ;;
esac
