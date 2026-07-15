#!/usr/bin/env bash

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/remote.sh"
source "$SCRIPT_DIR/lib/recovery.sh"
source "$SCRIPT_DIR/lib/installers.sh"
source "$SCRIPT_DIR/lib/plans.sh"

usage() {
  cat <<'EOF'
Usage:
  mint-jelly software install INSTALLER... [--allow-weak-verification]
  mint-jelly software list
  mint-jelly software config
  mint-jelly software backup [--remote NAME]
  mint-jelly software list-remote [--remote NAME] [--source-host HOSTNAME]
  mint-jelly software restore [--remote NAME] [--source-host HOSTNAME]
      [--dry-run] [--yes] [--allow-platform-mismatch]
      [--allow-weak-verification]
EOF
}

array_has() {
  local expected="$1" value
  shift
  for value in "$@"; do
    [[ "$value" == "$expected" ]] && return 0
  done
  return 1
}

installer_options() {
  local wanted="$1" selection
  local -a selected=()
  for selection in "${INSTALLER_OPTION_SELECTIONS[@]}"; do
    [[ "${selection%%:*}" == "$wanted" ]] && selected+=("${selection#*:}")
  done
  printf '%s' "${selected[*]}"
}

installer_verification_is_strong() {
  case "${INSTALLER_VERIFICATION[$1]}" in
    sha256-required|signature-required) return 0 ;;
    *) return 1 ;;
  esac
}

track_installer() {
  local installer="$1"
  if ! array_has "$installer" "${INSTALLERS[@]}"; then
    INSTALLERS+=("$installer")
    config_write
    log "Added software installer '$installer' to $MINT_JELLY_CONFIG_FILE"
  fi
}

install_one() {
  local installer="$1"
  local track="$2"
  local allow_weak="$3"
  local assume_yes="$4"
  local architecture status options option log_dir

  installer_exists "$installer" \
    || die "Unknown installer '$installer'. Available installers: ${INSTALLER_NAMES[*]:-none}"
  architecture="$(dpkg --print-architecture)"
  installer_supports_architecture "$installer" "$architecture" \
    || die "Installer '$installer' does not support architecture '$architecture'."
  options="$(installer_options "$installer")"
  for option in $options; do
    installer_option_exists "$installer" "$option" \
      || die "Unknown configured option '$option' for installer '$installer'."
  done

  if env MINT_JELLY_INSTALLER_OPTIONS="$options" \
    "${INSTALLER_RUN_SCRIPT[$installer]}" check >/dev/null 2>&1; then
    env MINT_JELLY_INSTALLER_OPTIONS="$options" \
      "${INSTALLER_RUN_SCRIPT[$installer]}" verify >/dev/null \
      || die "Installer '$installer' is present but failed verification."
    log "Software installer '$installer' is already satisfied."
    [[ "$track" == 'true' ]] && track_installer "$installer"
    return 0
  else
    status=$?
  fi
  (( status == 1 )) || die "Could not determine installation status for '$installer'."

  if ! installer_verification_is_strong "$installer"; then
    warn "Installer '$installer' uses limited verification: ${INSTALLER_VERIFICATION[$installer]}."
    if ! is_interactive && [[ "$allow_weak" != 'true' ]]; then
      die "Non-interactive installation of '$installer' requires --allow-weak-verification."
    fi
  fi
  if [[ "${INSTALLER_INTERACTIVE[$installer]}" == 'yes' ]] && ! is_interactive; then
    die "Installer '$installer' requires an interactive terminal."
  fi

  log_dir="$MINT_JELLY_STATE_DIR/software/$(date -u '+%Y%m%dT%H%M%S%NZ')/$installer"
  mkdir -p -- "$log_dir"
  chmod 0700 -- "$MINT_JELLY_STATE_DIR" "$MINT_JELLY_STATE_DIR/software" \
    "${log_dir%/*}" "$log_dir"
  log "Running installer '$installer': ${INSTALLER_DESCRIPTION[$installer]}"
  env MINT_JELLY_ASSUME_YES="$assume_yes" \
    MINT_JELLY_INSTALLER_STATE_DIR="$log_dir" \
    MINT_JELLY_INSTALLER_OPTIONS="$options" \
    "${INSTALLER_RUN_SCRIPT[$installer]}" install \
    || die "Installer '$installer' failed."
  env MINT_JELLY_INSTALLER_OPTIONS="$options" \
    "${INSTALLER_RUN_SCRIPT[$installer]}" verify \
    || die "Installer '$installer' completed but failed verification."
  [[ "$track" == 'true' ]] && track_installer "$installer"
}

select_remote() {
  local requested="$1"
  if [[ -n "$requested" ]]; then
    remote_exists "$requested" || die "Unknown backup remote: $requested"
    printf '%s' "$requested"
  else
    [[ -n "$DEFAULT_REMOTE" ]] \
      || die 'No default remote is configured. Run: mint-jelly config remote add'
    printf '%s' "$DEFAULT_REMOTE"
  fi
}

write_remote_plan() {
  local requested="$1"
  local selected hostname temporary

  selected="$(select_remote "$requested")"
  hostname="$(hostname)"
  temporary="$(mktemp "$MINT_JELLY_CONFIG_DIR/.software-plan.XXXXXX")"
  plan_reset
  PLAN_KIND='software'
  plan_populate_platform "$hostname"
  PLAN_ENTRIES=("${INSTALLERS[@]}")
  PLAN_OPTIONS=("${INSTALLER_OPTION_SELECTIONS[@]}")
  plan_write_file "$temporary"
  trap 'rm -f -- "$temporary"; remote_close; local_operation_lock_release' EXIT
  remote_open "$selected" "$hostname"
  remote_lock_acquire exclusive
  remote_write_manifest software "$temporary" "$PLAN_MAX_BYTES"
  remote_lock_release || die 'Could not release the remote operation lock.'
  remote_close
  rm -f -- "$temporary"
  trap - EXIT
  local_operation_lock_release
  log "Backed up ${#INSTALLERS[@]} software installer(s) to remote '$selected'."
}

read_remote_plan() {
  local requested="$1" source_host="$2"
  local selected temporary

  selected="$(select_remote "$requested")"
  [[ -n "$source_host" ]] || source_host="$(hostname)"
  validate_safe_name "$source_host" || die "Unsafe source hostname: $source_host"
  temporary="$(mktemp "$MINT_JELLY_CONFIG_DIR/.software-plan.XXXXXX")"
  PLAN_TEMP="$temporary"
  remote_open "$selected" "$source_host" read
  remote_lock_acquire shared
  remote_read_manifest software "$PLAN_MAX_BYTES" > "$temporary" \
    || die "No software manifest exists for '$source_host'."
  remote_lock_release || die 'Could not release the remote operation lock.'
  remote_close
  plan_read "$temporary"
  [[ "$PLAN_KIND" == 'software' ]] || die 'Remote manifest has the wrong domain.'
  [[ "$PLAN_HOSTNAME" == "$source_host" ]] || die 'Remote manifest hostname does not match the requested host.'
  rm -f -- "$temporary"
  PLAN_TEMP=''
  SELECTED_REMOTE_RESULT="$selected"
  SOURCE_HOST_RESULT="$source_host"
}

print_plan_entries() {
  local installer option
  for installer in "${PLAN_ENTRIES[@]}"; do
    printf '%s\n' "$installer"
    for option in "${PLAN_OPTIONS[@]}"; do
      [[ "${option%%:*}" == "$installer" ]] && printf '  option: %s\n' "${option#*:}"
    done
  done
}

confirm_restore() {
  local answer
  [[ "$1" == 'true' ]] && return 0
  is_interactive || die 'Software restore requires confirmation; use --yes after reviewing the plan.'
  printf 'Restore this software installer plan? [y/N]: '
  IFS= read -r answer
  [[ "${answer,,}" == 'y' || "${answer,,}" == 'yes' ]] || die 'Software restore cancelled.'
}

main() {
  local action="${1-}" requested_remote='' source_host='' dry_run='false'
  local assume_yes='false' allow_mismatch='false' allow_weak='false' installer
  local -a names=()

  [[ -n "$action" ]] && shift || true
  case "$action" in
    install)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --allow-weak-verification) allow_weak='true' ;;
          -h|--help) usage; return 0 ;;
          --*) die "Unknown software install argument: $1" ;;
          *) names+=("$1") ;;
        esac
        shift
      done
      (( ${#names[@]} > 0 )) || die 'software install requires at least one installer name.'
      (( EUID != 0 )) || die 'Run Mint Jelly as your desktop user, not as root.'
      require_cmd dpkg
      local_operation_lock_acquire
      trap local_operation_lock_release EXIT
      config_initialize_if_missing
      config_read
      load_installers
      for installer in "${names[@]}"; do
        install_one "$installer" true "$allow_weak" false
      done
      local_operation_lock_release
      trap - EXIT
      ;;
    list)
      [[ $# -eq 0 ]] || die 'software list does not accept arguments.'
      if [[ ! -f "$MINT_JELLY_CONFIG_FILE" ]]; then
        printf 'No software installers configured.\n'
        return 0
      fi
      config_read
      (( ${#INSTALLERS[@]} > 0 )) || { printf 'No software installers configured.\n'; return 0; }
      PLAN_ENTRIES=("${INSTALLERS[@]}")
      PLAN_OPTIONS=("${INSTALLER_OPTION_SELECTIONS[@]}")
      print_plan_entries
      ;;
    config)
      [[ $# -eq 0 ]] || die 'software config does not accept arguments.'
      local_operation_lock_acquire
      config_initialize_if_missing
      exec "$SCRIPT_DIR/configure-installers.sh"
      ;;
    backup)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --remote) [[ $# -ge 2 ]] || die '--remote requires a name.'; requested_remote="$2"; shift ;;
          -h|--help) usage; return 0 ;;
          *) die "Unknown software backup argument: $1" ;;
        esac
        shift
      done
      require_initialized_config
      local_operation_lock_acquire
      config_read
      load_installers
      require_configured_installers_available
      require_configured_installer_options_available
      write_remote_plan "$requested_remote"
      ;;
    list-remote|restore)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --remote) [[ $# -ge 2 ]] || die '--remote requires a name.'; requested_remote="$2"; shift ;;
          --source-host) [[ $# -ge 2 ]] || die '--source-host requires a hostname.'; source_host="$2"; shift ;;
          --dry-run) dry_run='true' ;;
          --yes) assume_yes='true' ;;
          --allow-platform-mismatch) allow_mismatch='true' ;;
          --allow-weak-verification) allow_weak='true' ;;
          -h|--help) usage; return 0 ;;
          *) die "Unknown software $action argument: $1" ;;
        esac
        shift
      done
      [[ "$action" == 'restore' || ( "$dry_run" == 'false' && "$assume_yes" == 'false' \
        && "$allow_mismatch" == 'false' && "$allow_weak" == 'false' ) ]] \
        || die 'software list-remote accepts only --remote and --source-host.'
      require_initialized_config
      local_operation_lock_acquire
      trap '[[ -z "${PLAN_TEMP:-}" ]] || rm -f -- "$PLAN_TEMP"; remote_close; local_operation_lock_release' EXIT
      config_read
      read_remote_plan "$requested_remote" "$source_host"
      printf 'Software plan from %s/%s, recorded %s:\n' \
        "$SELECTED_REMOTE_RESULT" "$SOURCE_HOST_RESULT" "$PLAN_CREATED_AT"
      print_plan_entries
      [[ "$action" == 'restore' ]] || return 0
      INSTALLERS=("${PLAN_ENTRIES[@]}")
      INSTALLER_OPTION_SELECTIONS=("${PLAN_OPTIONS[@]}")
      load_installers
      require_configured_installers_available
      require_configured_installer_options_available
      if ! plan_platform_matches_current "$(hostname)" && [[ "$allow_mismatch" != 'true' ]]; then
        die 'Refusing software restore from a different platform; use --allow-platform-mismatch after reviewing it.'
      fi
      [[ "$dry_run" == 'false' ]] || { log 'Dry run complete; no configuration or software was changed.'; return 0; }
      if [[ "$assume_yes" == 'true' && "$allow_weak" != 'true' ]]; then
        for installer in "${PLAN_ENTRIES[@]}"; do
          installer_verification_is_strong "$installer" \
            || die "Unattended restore of '$installer' requires --allow-weak-verification."
        done
      fi
      confirm_restore "$assume_yes"
      config_write
      for installer in "${INSTALLERS[@]}"; do
        install_one "$installer" false "$allow_weak" "$assume_yes"
      done
      log 'Software restore completed successfully.'
      ;;
    -h|--help|'') usage ;;
    *) die "Unknown software command: $action" ;;
  esac
}

main "$@"
