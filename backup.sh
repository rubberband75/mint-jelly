#!/usr/bin/env bash
# Back up one or every Mint Jelly domain into an atomic snapshot generation.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/remote.sh"
source "$SCRIPT_DIR/lib/snapshots.sh"
source "$SCRIPT_DIR/lib/application-profiles.sh"
source "$SCRIPT_DIR/lib/system-settings.sh"

usage() {
  printf 'Usage: %s [--remote NAME] [--domain all|files|software|system-settings] [--dry-run]\n' \
    "${MINT_JELLY_COMMAND:-mint-jelly backup}"
}

SELECTED_REMOTE=''
BACKUP_DOMAIN='all'
DRY_RUN='false'
TEMP_FILES=()
STAGE_STARTED='false'

cleanup() {
  local file
  if [[ "$STAGE_STARTED" == 'true' ]]; then snapshot_abort; fi
  for file in "${TEMP_FILES[@]}"; do rm -f -- "$file"; done
  remote_close
  local_operation_lock_release
}

manifest_new() {
  local variable="$1" domain="$2" file
  file="$(mktemp "$MINT_JELLY_CONFIG_DIR/.${domain}.manifest.XXXXXX")"
  TEMP_FILES+=("$file")
  {
    printf 'version=2\n'
    printf 'domain=%s\n' "$domain"
    printf 'hostname=%s\n' "$MACHINE_NAME"
    printf 'created_at=%s\n' "$RUN_TIMESTAMP"
    printf 'hardware=%s\n' "$(system_hardware_fingerprint)"
    printf 'os_id=%s\n' "$PLATFORM_OS_ID"
    printf 'os_version=%s\n' "$PLATFORM_OS_VERSION"
    printf 'architecture=%s\n' "$PLATFORM_ARCHITECTURE"
  } > "$file"
  printf -v "$variable" '%s' "$file"
}

encode_field() {
  printf '%s' "$1" | base64 -w0
}

backup_files_domain() {
  local manifest spec path count=0
  manifest_new manifest files
  [[ "$DRY_RUN" == 'true' ]] || snapshot_reset_domain files
  for spec in "${FILE_SPECS[@]}"; do
    path="$(resolve_file_spec "$spec")"
    if [[ ! -e "$path" && ! -L "$path" ]]; then
      warn "Skipping missing configured file path: $spec ($path)"
      continue
    fi
    printf 'path=%s\n' "$(encode_field "$path")" >> "$manifest"
    ((count += 1))
    if [[ "$DRY_RUN" == 'true' ]]; then
      log "Would back up file path $path"
    else
      log "Backing up file path $path"
      snapshot_sync_absolute "$path" files
    fi
  done
  printf 'count=%d\n' "$count" >> "$manifest"
  [[ "$DRY_RUN" == 'true' ]] || snapshot_upload_manifest files "$manifest"
}

backup_software_domain() {
  local manifest package installer option spec profile path count=0
  local -a effective_applications=("${APPLICATIONS[@]}")
  manifest_new manifest software
  require_configured_application_profiles
  application_auto_select_profiles
  effective_applications=("${APPLICATIONS[@]}")
  [[ "$DRY_RUN" == 'true' ]] || snapshot_reset_domain software
  for package in "${APT_PACKAGES[@]}"; do printf 'apt_package=%s\n' "$package" >> "$manifest"; done
  for installer in "${INSTALLERS[@]}"; do printf 'installer=%s\n' "$installer" >> "$manifest"; done
  for option in "${INSTALLER_OPTION_SELECTIONS[@]}"; do printf 'installer_option=%s\n' "$option" >> "$manifest"; done
  for spec in "${FLATPAK_APPS[@]}"; do printf 'flatpak_app=%s\n' "$spec" >> "$manifest"; done
  for profile in "${effective_applications[@]}"; do
    application_profile_exists "$profile" || die "Unknown application profile '$profile'."
    application_profile_preflight_backup "$profile"
    printf 'application=%s\n' "$profile" >> "$manifest"
    application_expand_profile_paths "$profile"
    if (( ${#APPLICATION_EXPANDED_PATHS[@]} == 0 )); then
      warn "No local configuration currently exists for ${APPLICATION_PROFILE_NAME[$profile]}."
      continue
    fi
    for path in "${APPLICATION_EXPANDED_PATHS[@]}"; do
      printf 'application_path=%s|%s\n' "$profile" "$(encode_field "$path")" >> "$manifest"
      ((count += 1))
      if [[ "$DRY_RUN" == 'true' ]]; then
        log "Would back up ${APPLICATION_PROFILE_NAME[$profile]} configuration: $path"
      else
        log "Backing up ${APPLICATION_PROFILE_NAME[$profile]} configuration: $path"
        snapshot_sync_absolute "$path" software
      fi
    done
  done
  printf 'application_path_count=%d\n' "$count" >> "$manifest"
  [[ "$DRY_RUN" == 'true' ]] || snapshot_upload_manifest software "$manifest"
}

backup_system_settings_domain() {
  local manifest profile pair schema key value path count=0
  manifest_new manifest system-settings
  require_cmd gsettings
  require_configured_system_settings
  [[ "$DRY_RUN" == 'true' ]] || snapshot_reset_domain system-settings
  for profile in "${SYSTEM_SETTINGS[@]}"; do
    printf 'profile=%s|%s\n' "$profile" "${SYSTEM_SETTING_CLASS[$profile]}" >> "$manifest"
    while IFS='|' read -r schema key; do
      [[ -n "$schema" && -n "$key" ]] || continue
      value="$(gsettings get "$schema" "$key")" \
        || die "Could not read $schema $key"
      printf 'value=%s|%s|%s|%s\n' "$profile" "$schema" "$key" "$(encode_field "$value")" >> "$manifest"
      ((count += 1))
    done < <(system_setting_schema_keys "$profile")
    system_setting_expand_files "$profile"
    for path in "${SYSTEM_SETTING_EXPANDED_FILES[@]}"; do
      printf 'asset=%s|%s\n' "$profile" "$(encode_field "$path")" >> "$manifest"
      if [[ "$DRY_RUN" == 'true' ]]; then
        log "Would back up ${SYSTEM_SETTING_NAME[$profile]} asset: $path"
      else
        log "Backing up ${SYSTEM_SETTING_NAME[$profile]} asset: $path"
        snapshot_sync_absolute "$path" system-settings
      fi
    done
  done
  printf 'value_count=%d\n' "$count" >> "$manifest"
  [[ "$DRY_RUN" == 'true' ]] || snapshot_upload_manifest system-settings "$manifest"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote) [[ $# -ge 2 ]] || die '--remote requires a name.'; SELECTED_REMOTE="$2"; shift 2 ;;
    --domain) [[ $# -ge 2 ]] || die '--domain requires a value.'; BACKUP_DOMAIN="$2"; shift 2 ;;
    --dry-run) DRY_RUN='true'; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown backup argument: $1" ;;
  esac
done
case "$BACKUP_DOMAIN" in all|files|software|system-settings) ;; *) die "Unknown backup domain: $BACKUP_DOMAIN" ;; esac

require_cmd base64
require_cmd hostname
require_cmd rsync
require_initialized_config
local_operation_lock_acquire
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
config_read
[[ -n "$SELECTED_REMOTE" ]] || SELECTED_REMOTE="$DEFAULT_REMOTE"
[[ -n "$SELECTED_REMOTE" ]] || die 'No default remote is configured. Run: mint-jelly config remote add'
remote_exists "$SELECTED_REMOTE" || die "Unknown backup remote: $SELECTED_REMOTE"
MACHINE_NAME="$(hostname)"
validate_safe_name "$MACHINE_NAME" || die "Unsafe local hostname: $MACHINE_NAME"
RUN_TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
PLATFORM_OS_ID='unknown'
PLATFORM_OS_VERSION='unknown'
if [[ -r /etc/os-release ]]; then
  # /etc/os-release is an operating-system owned shell-compatible data file.
  source /etc/os-release
  PLATFORM_OS_ID="${ID:-unknown}"
  PLATFORM_OS_VERSION="${VERSION_ID:-unknown}"
fi
PLATFORM_ARCHITECTURE="$(dpkg --print-architecture 2>/dev/null || uname -m)"

if [[ "$DRY_RUN" == 'true' ]]; then
  case "$BACKUP_DOMAIN" in all|files) backup_files_domain ;; esac
  case "$BACKUP_DOMAIN" in all|software) backup_software_domain ;; esac
  case "$BACKUP_DOMAIN" in all|system-settings) backup_system_settings_domain ;; esac
  log 'Backup dry run completed; no remote data was changed.'
  exit 0
fi

remote_open "$SELECTED_REMOTE" "$MACHINE_NAME"
remote_lock_acquire exclusive
snapshot_begin true
STAGE_STARTED='true'
case "$BACKUP_DOMAIN" in all|files) backup_files_domain ;; esac
case "$BACKUP_DOMAIN" in all|software) backup_software_domain ;; esac
case "$BACKUP_DOMAIN" in all|system-settings) backup_system_settings_domain ;; esac
manifest_new snapshot_manifest snapshot
printf 'updated_domain=%s\n' "$BACKUP_DOMAIN" >> "$snapshot_manifest"
snapshot_upload_manifest snapshot "$snapshot_manifest"
snapshot_commit "$HISTORY_KEEP"
STAGE_STARTED='false'
remote_lock_release || die 'Could not release the remote operation lock.'
remote_close
local_operation_lock_release
trap - EXIT
log "Committed snapshot $SNAPSHOT_ID to remote '$SELECTED_REMOTE'."
