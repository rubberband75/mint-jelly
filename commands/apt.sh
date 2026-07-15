#!/usr/bin/env bash

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/remote.sh"
source "$SCRIPT_DIR/lib/recovery.sh"
source "$SCRIPT_DIR/lib/plans.sh"
source "$SCRIPT_DIR/configure-apt.sh"

usage() {
  cat <<'EOF'
Usage:
  mint-jelly apt install PACKAGE... [--yes]
  mint-jelly apt add PACKAGE...
  mint-jelly apt remove PACKAGE...
  mint-jelly apt list
  mint-jelly apt config [--show-all]
  mint-jelly apt backup [--remote NAME]
  mint-jelly apt list-remote [--remote NAME] [--source-host HOSTNAME]
  mint-jelly apt restore [--remote NAME] [--source-host HOSTNAME]
      [--dry-run] [--yes] [--allow-platform-mismatch]

add and remove only change the recovery plan; they never install or uninstall.
EOF
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

apt_install_packages() {
  local assume_yes="$1"
  shift
  local package
  local -a command=(sudo apt-get install)

  (( $# > 0 )) || return 0
  require_cmd sudo
  require_cmd apt-get
  require_cmd dpkg-query
  for package in "$@"; do
    validate_apt_package_name "$package" || die "Invalid APT package name: $package"
  done
  [[ "$assume_yes" != 'true' ]] || command+=(--yes)
  command+=("$@")
  "${command[@]}" || die 'APT package installation failed.'
  for package in "$@"; do
    output="$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)"
    [[ "$output" == 'install ok installed' ]] \
      || die "APT reported success, but '$package' is not installed."
  done
}

track_packages() {
  local package existing
  local changed='false'
  for package in "$@"; do
    existing='false'
    for configured in "${APT_PACKAGES[@]}"; do
      [[ "$configured" == "$package" ]] && existing='true'
    done
    if [[ "$existing" == 'false' ]]; then
      APT_PACKAGES+=("$package")
      changed='true'
    fi
  done
  if [[ "$changed" == 'true' ]]; then
    config_write
    log "Updated the local APT recovery plan: $*"
  fi
}

write_remote_plan() {
  local requested="$1" selected hostname temporary
  selected="$(select_remote "$requested")"
  hostname="$(hostname)"
  temporary="$(mktemp "$MINT_JELLY_CONFIG_DIR/.apt-plan.XXXXXX")"
  plan_reset
  PLAN_KIND='apt'
  plan_populate_platform "$hostname"
  PLAN_ENTRIES=("${APT_PACKAGES[@]}")
  plan_write_file "$temporary"
  trap 'rm -f -- "$temporary"; remote_close; local_operation_lock_release' EXIT
  remote_open "$selected" "$hostname"
  remote_lock_acquire exclusive
  remote_write_manifest apt "$temporary" "$PLAN_MAX_BYTES"
  remote_lock_release || die 'Could not release the remote operation lock.'
  remote_close
  rm -f -- "$temporary"
  trap - EXIT
  local_operation_lock_release
  log "Backed up ${#APT_PACKAGES[@]} APT package(s) to remote '$selected'."
}

read_remote_plan() {
  local requested="$1" source_host="$2" selected temporary
  selected="$(select_remote "$requested")"
  [[ -n "$source_host" ]] || source_host="$(hostname)"
  validate_safe_name "$source_host" || die "Unsafe source hostname: $source_host"
  temporary="$(mktemp "$MINT_JELLY_CONFIG_DIR/.apt-plan.XXXXXX")"
  PLAN_TEMP="$temporary"
  remote_open "$selected" "$source_host" read
  remote_lock_acquire shared
  remote_read_manifest apt "$PLAN_MAX_BYTES" > "$temporary" \
    || die "No APT manifest exists for '$source_host'."
  remote_lock_release || die 'Could not release the remote operation lock.'
  remote_close
  plan_read "$temporary"
  rm -f -- "$temporary"
  PLAN_TEMP=''
  [[ "$PLAN_KIND" == 'apt' ]] || die 'Remote manifest has the wrong domain.'
  [[ "$PLAN_HOSTNAME" == "$source_host" ]] || die 'Remote manifest hostname does not match the requested host.'
  SELECTED_REMOTE_RESULT="$selected"
  SOURCE_HOST_RESULT="$source_host"
}

confirm_restore() {
  local answer
  [[ "$1" == 'true' ]] && return 0
  is_interactive || die 'APT restore requires confirmation; use --yes after reviewing the plan.'
  printf 'Restore this APT package plan? [y/N]: '
  IFS= read -r answer
  [[ "${answer,,}" == 'y' || "${answer,,}" == 'yes' ]] || die 'APT restore cancelled.'
}

main() {
  local action="${1-}" requested_remote='' source_host='' dry_run='false'
  local assume_yes='false' allow_mismatch='false' show_all='false' package
  local -a values=() missing=()

  [[ -n "$action" ]] && shift || true
  case "$action" in
    install)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --yes) assume_yes='true' ;;
          -h|--help) usage; return 0 ;;
          --*) die "Unknown apt install argument: $1" ;;
          *) values+=("$1") ;;
        esac
        shift
      done
      (( ${#values[@]} > 0 )) || die 'apt install requires at least one package name.'
      (( EUID != 0 )) || die 'Run Mint Jelly as your desktop user, not as root.'
      local_operation_lock_acquire
      trap local_operation_lock_release EXIT
      config_initialize_if_missing
      config_read
      apt_install_packages "$assume_yes" "${values[@]}"
      track_packages "${values[@]}"
      local_operation_lock_release
      trap - EXIT
      ;;
    add|remove)
      (( $# > 0 )) || die "apt $action requires at least one package name."
      local_operation_lock_acquire
      trap local_operation_lock_release EXIT
      config_initialize_if_missing
      config_read
      if [[ "$action" == 'add' ]]; then
        add_packages "$@"
      else
        remove_packages "$@"
      fi
      local_operation_lock_release
      trap - EXIT
      ;;
    list)
      [[ $# -eq 0 ]] || die 'apt list does not accept arguments.'
      [[ -f "$MINT_JELLY_CONFIG_FILE" ]] || { printf 'No APT packages configured.\n'; return 0; }
      config_read
      (( ${#APT_PACKAGES[@]} > 0 )) || { printf 'No APT packages configured.\n'; return 0; }
      printf '%s\n' "${APT_PACKAGES[@]}"
      ;;
    config)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --show-all) show_all='true' ;;
          -h|--help) usage; return 0 ;;
          *) die "Unknown apt config argument: $1" ;;
        esac
        shift
      done
      local_operation_lock_acquire
      trap local_operation_lock_release EXIT
      config_initialize_if_missing
      config_read
      select_packages "$show_all"
      local_operation_lock_release
      trap - EXIT
      ;;
    backup)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --remote) [[ $# -ge 2 ]] || die '--remote requires a name.'; requested_remote="$2"; shift ;;
          -h|--help) usage; return 0 ;;
          *) die "Unknown apt backup argument: $1" ;;
        esac
        shift
      done
      require_initialized_config
      local_operation_lock_acquire
      config_read
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
          -h|--help) usage; return 0 ;;
          *) die "Unknown apt $action argument: $1" ;;
        esac
        shift
      done
      [[ "$action" == 'restore' || ( "$dry_run" == 'false' && "$assume_yes" == 'false' \
        && "$allow_mismatch" == 'false' ) ]] \
        || die 'apt list-remote accepts only --remote and --source-host.'
      require_initialized_config
      local_operation_lock_acquire
      trap '[[ -z "${PLAN_TEMP:-}" ]] || rm -f -- "$PLAN_TEMP"; remote_close; local_operation_lock_release' EXIT
      config_read
      read_remote_plan "$requested_remote" "$source_host"
      printf 'APT plan from %s/%s, recorded %s:\n' \
        "$SELECTED_REMOTE_RESULT" "$SOURCE_HOST_RESULT" "$PLAN_CREATED_AT"
      printf '%s\n' "${PLAN_ENTRIES[@]}"
      [[ "$action" == 'restore' ]] || return 0
      if ! plan_platform_matches_current "$(hostname)" && [[ "$allow_mismatch" != 'true' ]]; then
        die 'Refusing APT restore from a different platform; use --allow-platform-mismatch after reviewing it.'
      fi
      require_cmd dpkg-query
      for package in "${PLAN_ENTRIES[@]}"; do
        output="$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)"
        [[ "$output" == 'install ok installed' ]] || missing+=("$package")
      done
      printf 'Missing packages: %d\n' "${#missing[@]}"
      [[ "$dry_run" == 'false' ]] || { log 'Dry run complete; no configuration or packages were changed.'; return 0; }
      confirm_restore "$assume_yes"
      APT_PACKAGES=("${PLAN_ENTRIES[@]}")
      config_write
      apt_install_packages "$assume_yes" "${missing[@]}"
      log 'APT restore completed successfully.'
      ;;
    -h|--help|'') usage ;;
    *) die "Unknown apt command: $action" ;;
  esac
}

main "$@"
