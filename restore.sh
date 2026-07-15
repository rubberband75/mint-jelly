#!/usr/bin/env bash
# Restore a computer's current backup mirror to its original absolute paths.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/remote.sh
source "$SCRIPT_DIR/lib/remote.sh"
# shellcheck source=lib/backup-plugins.sh
source "$SCRIPT_DIR/lib/backup-plugins.sh"
# shellcheck source=lib/recovery.sh
source "$SCRIPT_DIR/lib/recovery.sh"

usage() {
  cat <<EOF
Usage: ${MINT_JELLY_COMMAND:-mint-jelly restore} [--remote NAME] [--source-host HOSTNAME]
       [--dry-run] [--yes] [--allow-platform-mismatch]

Restores the selected computer's current mirror to its original absolute paths.
Files that are not represented in the backup are not deleted.
EOF
}

validate_restore_platform() {
  if [[ "$RECOVERY_OS_ID" == "$CURRENT_OS_ID" \
    && "$RECOVERY_OS_VERSION" == "$CURRENT_OS_VERSION" \
    && "$RECOVERY_UBUNTU_CODENAME" == "$CURRENT_UBUNTU_CODENAME" \
    && "$RECOVERY_ARCHITECTURE" == "$CURRENT_ARCHITECTURE" ]]; then
    return 0
  fi

  warn 'The recovery manifest was created on a different operating-system platform.'
  printf '  Recorded: %s %s (%s, Ubuntu %s)\n' \
    "$RECOVERY_OS_ID" "$RECOVERY_OS_VERSION" \
    "$RECOVERY_ARCHITECTURE" "$RECOVERY_UBUNTU_CODENAME" >&2
  printf '  Current:  %s %s (%s, Ubuntu %s)\n' \
    "$CURRENT_OS_ID" "$CURRENT_OS_VERSION" \
    "$CURRENT_ARCHITECTURE" "$CURRENT_UBUNTU_CODENAME" >&2
  [[ "$ALLOW_PLATFORM_MISMATCH" == 'true' ]] \
    || die 'Refusing restore on a different platform. Use --allow-platform-mismatch only after reviewing the recorded platform.'
  warn 'Platform mismatch override accepted; restored settings may be incompatible.'
}

confirm_restore() {
  local answer source

  [[ "$ASSUME_YES" == 'true' ]] && return 0
  is_interactive \
    || die 'Restore requires interactive confirmation. Re-run with --yes to confirm non-interactively.'

  printf '\nRestore source:\n'
  printf '  Remote:      %s\n' "$SELECTED_REMOTE"
  printf '  Source host: %s\n' "$SOURCE_HOST"
  printf '  Mirror:      %s\n' "$ACTIVE_HOST_BASE"
  printf '  Destination: / (original absolute paths)\n\n'
  printf 'Sources:\n'
  for source in "${RESTORE_SOURCES[@]}"; do
    printf '  %s\n' "$source"
  done
  printf '\n'
  printf 'Existing files at matching paths may be overwritten.\n'
  printf 'Files absent from the backup will not be deleted.\n\n'
  printf 'Continue with restore? [y/N]: '
  IFS= read -r answer
  case "${answer,,}" in
    y|yes) ;;
    *) die 'Restore cancelled.' ;;
  esac
}

cleanup() {
  if [[ -n "$MANIFEST_TEMP" ]]; then
    rm -f -- "$MANIFEST_TEMP" || true
  fi
  remote_close
}

add_restore_source() {
  local candidate="$1"
  local existing

  validate_absolute_path "$candidate" \
    || die "Backup manifest contains an unsafe source path: $candidate"
  for existing in "${RESTORE_SOURCES[@]}"; do
    [[ "$candidate" != "$existing" ]] \
      || die "Backup manifest contains a duplicate source: $candidate"
    [[ "$candidate" != "$existing/"* && "$existing" != "$candidate/"* ]] \
      || die "Backup manifest contains overlapping sources: $existing and $candidate"
  done
  RESTORE_SOURCES+=("$candidate")
}

restore_path_is_included() {
  local path="$1"
  local source

  validate_absolute_path "$path" || return 1
  for source in "${RESTORE_SOURCES[@]}"; do
    if [[ "$path" == "$source" || "$path" == "$source/"* ]]; then
      return 0
    fi
  done
  return 1
}

load_recovery_manifest() {
  local source

  MANIFEST_TEMP="$(mktemp "${MINT_JELLY_CONFIG_DIR}/.restore-sources.XXXXXX")"
  chmod 0600 -- "$MANIFEST_TEMP"
  remote_read_recovery_manifest > "$MANIFEST_TEMP" \
    || die "No valid recovery manifest exists for '$SOURCE_HOST'. Run a new backup with this version of Mint Jelly first."
  recovery_read "$MANIFEST_TEMP"
  [[ "$RECOVERY_HOSTNAME" == "$SOURCE_HOST" ]] \
    || die "Recovery manifest hostname '$RECOVERY_HOSTNAME' does not match requested source host '$SOURCE_HOST'."

  for source in "${RECOVERY_SOURCES[@]}"; do
    add_restore_source "$source"
  done
  BACKUP_PLUGINS=("${RECOVERY_BACKUP_PLUGINS[@]}")
  require_configured_plugins_available

  for source in "${RESTORE_SOURCES[@]}"; do
    remote_backup_source_exists "$source" \
      || die "A source listed in the recovery manifest is missing: $source"
  done
}

run_restore() {
  local dry_run="$1"
  local source

  for source in "${RESTORE_SOURCES[@]}"; do
    log "Restoring $source"
    remote_restore_source "$source" "$dry_run"
  done
}

SELECTED_REMOTE=''
SOURCE_HOST=''
DRY_RUN='false'
ASSUME_YES='false'
ALLOW_PLATFORM_MISMATCH='false'
MANIFEST_TEMP=''
RESTORE_SOURCES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote)
      [[ $# -ge 2 ]] || die '--remote requires a name.'
      SELECTED_REMOTE="$2"
      shift 2
      ;;
    --source-host)
      [[ $# -ge 2 ]] || die '--source-host requires a hostname.'
      SOURCE_HOST="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN='true'
      shift
      ;;
    --yes)
      ASSUME_YES='true'
      shift
      ;;
    --allow-platform-mismatch)
      ALLOW_PLATFORM_MISMATCH='true'
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

require_cmd flock
require_cmd hostname
require_initialized_config
load_backup_plugins
config_read

if [[ -z "$SELECTED_REMOTE" ]]; then
  [[ -n "$DEFAULT_REMOTE" ]] \
    || die 'No default remote is configured. Run: mint-jelly config remote add'
  SELECTED_REMOTE="$DEFAULT_REMOTE"
fi
remote_exists "$SELECTED_REMOTE" \
  || die "Unknown backup remote: $SELECTED_REMOTE"

[[ -n "$SOURCE_HOST" ]] || SOURCE_HOST="$(hostname)"
validate_safe_name "$SOURCE_HOST" || die "Unsafe source hostname: $SOURCE_HOST"

ensure_config_dir
exec 9>"$MINT_JELLY_CONFIG_DIR/operation.lock"
flock -n 9 || die 'Another Mint Jelly backup, restore, or software operation is already running.'

recovery_reset
recovery_populate_platform "$(hostname)"
CURRENT_OS_ID="$RECOVERY_OS_ID"
CURRENT_OS_VERSION="$RECOVERY_OS_VERSION"
CURRENT_UBUNTU_CODENAME="$RECOVERY_UBUNTU_CODENAME"
CURRENT_ARCHITECTURE="$RECOVERY_ARCHITECTURE"

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
remote_open "$SELECTED_REMOTE" "$SOURCE_HOST" read
remote_lock_acquire shared
load_recovery_manifest
validate_restore_platform

log "Restore source: $ACTIVE_HOST_BASE"
if [[ "$DRY_RUN" == 'true' ]]; then
  log 'Dry-run mode: no files or desktop settings will be changed.'
  run_restore true
  remote_lock_verify
  remote_lock_release \
    || die 'Could not release the shared remote operation lock cleanly.'
  remote_close
  log 'Restore dry run completed successfully.'
  exit 0
fi

preflight_configured_restore_plugins
confirm_restore
run_restore false
apply_configured_restore_plugins
remote_lock_verify
remote_lock_release \
  || die 'Could not release the shared remote operation lock cleanly.'
remote_close
log "Restore completed successfully from remote '$SELECTED_REMOTE' for host '$SOURCE_HOST'."
