#!/usr/bin/env bash
# Back up configured files to a local or SSH remote using absolute paths.

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
# shellcheck source=lib/installers.sh
source "$SCRIPT_DIR/lib/installers.sh"
# shellcheck source=lib/recovery.sh
source "$SCRIPT_DIR/lib/recovery.sh"

usage() {
  printf 'Usage: %s [--remote NAME] [--dry-run]\n' \
    "${MINT_JELLY_COMMAND:-mint-jelly backup}"
}

SELECTED_REMOTE=''
DRY_RUN='false'
SOURCES=()
MANIFEST_SOURCES=()
RECOVERY_TEMP=''

cleanup() {
  [[ -z "$RECOVERY_TEMP" ]] || rm -f -- "$RECOVERY_TEMP"
  remote_close
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote)
      [[ $# -ge 2 ]] || die '--remote requires a name.'
      SELECTED_REMOTE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN='true'
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

add_source() {
  local candidate="${1%/}"
  local existing
  local -a kept=()

  [[ -n "$candidate" ]] || candidate='/'
  for existing in "${SOURCES[@]}"; do
    if [[ "$candidate" == "$existing" || "$candidate" == "$existing/"* ]]; then
      return
    fi
  done

  for existing in "${SOURCES[@]}"; do
    [[ "$existing" == "$candidate/"* ]] || kept+=("$existing")
  done
  SOURCES=("${kept[@]}" "$candidate")
}

add_manifest_source() {
  local candidate="${1%/}"
  local existing
  local -a kept=()

  [[ -n "$candidate" ]] || candidate='/'
  for existing in "${MANIFEST_SOURCES[@]}"; do
    if [[ "$candidate" == "$existing" || "$candidate" == "$existing/"* ]]; then
      return
    fi
  done

  for existing in "${MANIFEST_SOURCES[@]}"; do
    [[ "$existing" == "$candidate/"* ]] || kept+=("$existing")
  done
  MANIFEST_SOURCES=("${kept[@]}" "$candidate")
}

local_destination_is_safe() {
  local source="$1"
  local destination="$2"
  local normalized_source normalized_destination

  normalized_source="$(realpath -m -- "$source")"
  normalized_destination="$(realpath -m -- "$destination")"
  [[ "$normalized_destination" != "$normalized_source" \
    && "$normalized_destination" != "$normalized_source/"* ]]
}

backup_source() {
  local source="$1"
  local relative_path="${source#/}"
  local parent_path destination history_destination source_argument destination_argument

  if [[ -d "$source" && ! -L "$source" ]]; then
    destination="${ACTIVE_HOST_BASE}/${relative_path}"
    history_destination="${ACTIVE_HOST_BASE}/.history/${RUN_TIMESTAMP}/${relative_path}"
    remote_ensure_directory "$destination"
    source_argument="${source}/"
    destination_argument="${destination}/"
  else
    if [[ "$relative_path" == */* ]]; then
      parent_path="${relative_path%/*}"
      destination="${ACTIVE_HOST_BASE}/${parent_path}"
      history_destination="${ACTIVE_HOST_BASE}/.history/${RUN_TIMESTAMP}/${parent_path}"
    else
      destination="$ACTIVE_HOST_BASE"
      history_destination="${ACTIVE_HOST_BASE}/.history/${RUN_TIMESTAMP}"
    fi
    remote_ensure_directory "$destination"
    source_argument="$source"
    destination_argument="${destination}/"
  fi

  log "Backing up $source"
  remote_rsync "$source_argument" "$destination_argument" "$history_destination" "$DRY_RUN"
}

require_cmd flock
require_cmd hostname
require_cmd realpath
require_initialized_config
load_backup_plugins
load_installers

config_read
require_configured_installers_available
if [[ -z "$SELECTED_REMOTE" ]]; then
  [[ -n "$DEFAULT_REMOTE" ]] \
    || die 'No default remote is configured. Run: mint-jelly config remote add'
  SELECTED_REMOTE="$DEFAULT_REMOTE"
fi
remote_exists "$SELECTED_REMOTE" \
  || die "Unknown backup remote: $SELECTED_REMOTE"

ensure_config_dir
exec 9>"$MINT_JELLY_CONFIG_DIR/operation.lock"
flock -n 9 || die 'Another Mint Jelly backup, restore, or software operation is already running.'

for source_spec in "${BACKUP_SOURCE_SPECS[@]}"; do
  source="$(resolve_backup_source_spec "$source_spec")"
  [[ -e "$source" || -L "$source" ]] \
    || die "Configured backup source does not exist: $source_spec ($source)"
  add_source "$source"
done

prepare_configured_backup_plugins
for source in "${BACKUP_PLUGIN_SOURCES[@]}"; do
  add_source "$source"
done
(( ${#SOURCES[@]} + ${#BACKUP_PLUGIN_RETAINED_SOURCES[@]} > 0 )) \
  || die 'No existing backup sources were configured or discovered.'

for source in "${SOURCES[@]}"; do
  if [[ "$source" == "$HOME/.ssh" || "$HOME/.ssh" == "$source/"* ]]; then
    warn 'SSH private keys will be copied without client-side encryption; secure the backup server at rest.'
    break
  fi
done

MACHINE_NAME="$(hostname)"
validate_safe_name "$MACHINE_NAME" || die "Unsafe local hostname: $MACHINE_NAME"
RUN_TIMESTAMP="$(date -u '+%Y%m%dT%H%M%SZ')"

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
remote_open "$SELECTED_REMOTE" "$MACHINE_NAME"
remote_lock_acquire exclusive

if [[ "$ACTIVE_REMOTE_TYPE" == 'local' ]]; then
  for source in "${SOURCES[@]}"; do
    local_destination_is_safe "$source" "$ACTIVE_HOST_BASE" \
      || die "Backup destination is inside source path: $source"
  done
fi

log "Backup destination: $ACTIVE_HOST_BASE"
[[ "$DRY_RUN" == 'true' ]] && log 'Dry-run mode: rsync will not transfer or delete files.'
for source in "${SOURCES[@]}"; do
  add_manifest_source "$source"
done
for source in "${BACKUP_PLUGIN_RETAINED_SOURCES[@]}"; do
  if remote_backup_source_exists "$source"; then
    add_manifest_source "$source"
    log "Retaining the previous backup of $source"
  else
    warn "No previous backup exists for skipped source: $source"
  fi
done
(( ${#MANIFEST_SOURCES[@]} > 0 )) \
  || die 'No sources were transferred and no previous skipped-source backups exist to retain.'

RECOVERY_TEMP="$(mktemp "${MINT_JELLY_CONFIG_DIR}/.recovery-manifest.XXXXXX")"
recovery_reset
recovery_populate_platform "$MACHINE_NAME"
RECOVERY_SOURCES=("${MANIFEST_SOURCES[@]}")
RECOVERY_BACKUP_PLUGINS=("${BACKUP_PLUGINS[@]}")
RECOVERY_APT_PACKAGES=("${APT_PACKAGES[@]}")
RECOVERY_INSTALLERS=("${INSTALLERS[@]}")
recovery_write_file "$RECOVERY_TEMP"

if [[ "$DRY_RUN" == 'false' ]]; then
  # A failed or interrupted run must not leave a valid recovery manifest
  # pointing at a partially updated mirror. It is committed only after every
  # source has synchronized successfully.
  remote_invalidate_recovery_manifest
fi
for source in "${SOURCES[@]}"; do
  backup_source "$source"
done

if [[ "$DRY_RUN" == 'true' ]]; then
  remote_lock_verify
  remote_lock_release \
    || die 'Could not release the exclusive remote operation lock cleanly.'
  remote_close
  log 'Dry run completed successfully.'
else
  remote_write_recovery_manifest "$RECOVERY_TEMP"
  remote_lock_verify
  log "Backup data and recovery manifest committed successfully to remote '$SELECTED_REMOTE'."
  log "Keeping the newest $HISTORY_KEEP non-empty history generation(s)."
  if ! remote_cleanup_history "$HISTORY_KEEP"; then
    warn 'Backup succeeded, but expired history generations could not be cleaned up.'
  fi
  remote_lock_verify
  remote_lock_release \
    || die 'Could not release the exclusive remote operation lock cleanly.'
  remote_close
  log "Backup completed successfully to remote '$SELECTED_REMOTE'."
fi
