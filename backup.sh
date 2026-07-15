#!/usr/bin/env bash
# Back up one or every Mint Jelly domain into an atomic snapshot generation.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/domains.sh"
source "$SCRIPT_DIR/lib/remote.sh"
source "$SCRIPT_DIR/lib/snapshots.sh"
source "$SCRIPT_DIR/lib/application-profiles.sh"
source "$SCRIPT_DIR/lib/repositories.sh"
source "$SCRIPT_DIR/lib/system-settings.sh"

usage() {
  printf 'Usage: %s [--remote NAME] [--domain all|%s] [--repository NAME] [--dry-run]\n' \
    "${MINT_JELLY_COMMAND:-mint-jelly backup}" "$(domain_list_pipe_separated)"
}

SELECTED_REMOTE=''
BACKUP_DOMAIN='all'
DRY_RUN='false'
TEMP_FILES=()
TEMP_DIRS=()
REQUESTED_REPOSITORIES=()
STAGE_STARTED='false'
COPY_CURRENT_SNAPSHOT='true'

cleanup() {
  local file directory
  if [[ -n "$SNAPSHOT_STAGE" ]]; then snapshot_abort; fi
  for file in "${TEMP_FILES[@]}"; do rm -f -- "$file"; done
  for directory in "${TEMP_DIRS[@]}"; do rm -rf -- "$directory"; done
  remote_close
  local_operation_lock_release
}

manifest_new() {
  local variable="$1" domain="$2" file
  file="$(mktemp "$MINT_JELLY_CONFIG_DIR/.${domain}.manifest.XXXXXX")"
  TEMP_FILES+=("$file")
  {
    printf 'version=%s\n' "$SNAPSHOT_FORMAT"
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

repository_backup_is_requested() {
  local wanted="$1" requested

  (( ${#REQUESTED_REPOSITORIES[@]} == 0 )) && return 0
  for requested in "${REQUESTED_REPOSITORIES[@]}"; do
    [[ "$requested" == "$wanted" ]] && return 0
  done
  return 1
}

backup_repositories_domain() {
  local manifest name configured_path source artifact build_root cache_root count=0
  local scratch metadata_root metadata_dir encoded selected_list staged_output
  local -a includes=() excludes=() capture_names=() staged_names=()

  if [[ "$DRY_RUN" == 'true' ]]; then
    for name in "${REPOSITORY_NAMES[@]}"; do
      repository_backup_is_requested "$name" || continue
      source="$(resolve_repository_path "${REPOSITORY_PATH[$name]}")"
      repository_preflight_source "$name" "$source"
      config_repository_get_includes "$name" includes
      for configured_path in "${includes[@]}"; do
        [[ -e "$source/$configured_path" || -L "$source/$configured_path" ]] \
          || die "Required repository include does not exist: $name/$configured_path"
      done
      selected_list="$(mktemp "$MINT_JELLY_CONFIG_DIR/.repository-selection.XXXXXX")"
      TEMP_FILES+=("$selected_list")
      config_repository_get_excludes "$name" excludes
      repository_build_file_list "$source" "$selected_list" includes excludes
      log "Would back up repository '$name': $source"
    done
    return 0
  fi

  [[ ! -L "$MINT_JELLY_STATE_DIR" \
    && ( ! -e "$MINT_JELLY_STATE_DIR" || -d "$MINT_JELLY_STATE_DIR" ) ]] \
    || die "Unsafe Mint Jelly state directory: $MINT_JELLY_STATE_DIR"
  [[ ! -L "$MINT_JELLY_CACHE_DIR" \
    && ( ! -e "$MINT_JELLY_CACHE_DIR" || -d "$MINT_JELLY_CACHE_DIR" ) ]] \
    || die "Unsafe Mint Jelly cache directory: $MINT_JELLY_CACHE_DIR"
  [[ ! -L "$MINT_JELLY_CACHE_DIR/repositories" \
    && ( ! -e "$MINT_JELLY_CACHE_DIR/repositories" || -d "$MINT_JELLY_CACHE_DIR/repositories" ) ]] \
    || die "Unsafe repository cache directory: $MINT_JELLY_CACHE_DIR/repositories"
  mkdir -p -- "$MINT_JELLY_STATE_DIR" "$MINT_JELLY_CACHE_DIR/repositories"
  chmod 0700 -- "$MINT_JELLY_STATE_DIR" "$MINT_JELLY_CACHE_DIR" "$MINT_JELLY_CACHE_DIR/repositories"
  build_root="$(mktemp -d "$MINT_JELLY_STATE_DIR/.repositories-build.XXXXXX")"
  TEMP_DIRS+=("$build_root")
  cache_root="$MINT_JELLY_CACHE_DIR/repositories"
  scratch="$build_root/.verify"
  mkdir -- "$scratch"
  if (( ${#REQUESTED_REPOSITORIES[@]} == 0 )); then
    snapshot_prepare_structured_domain repositories "${REPOSITORY_NAMES[@]}"
    capture_names=("${REPOSITORY_NAMES[@]}")
  else
    snapshot_prepare_structured_domain repositories --preserve-all
    capture_names=("${REQUESTED_REPOSITORIES[@]}")
  fi

  for name in "${capture_names[@]}"; do

    source="$(resolve_repository_path "${REPOSITORY_PATH[$name]}")"
    artifact="$build_root/$name"
    config_repository_get_includes "$name" includes
    config_repository_get_excludes "$name" excludes
    log "Backing up repository '$name': $source"
    repository_capture_artifact "$name" "$source" "$artifact" "$cache_root" includes excludes
    repository_verify_artifact "$artifact" "$name" "$scratch"
    snapshot_sync_domain_entry "$artifact" repositories "$name"
    rm -rf -- "$artifact"
  done

  staged_output="$(snapshot_list_staged_domain_entries repositories)" \
    || die 'Could not list staged repository artifacts.'
  [[ -z "$staged_output" ]] || mapfile -t staged_names <<< "$staged_output"
  manifest_new manifest repositories
  metadata_root="$build_root/.metadata"
  mkdir -- "$metadata_root"
  for name in "${staged_names[@]}"; do
    metadata_dir="$metadata_root/$name"
    mkdir -- "$metadata_dir"
    snapshot_download_staged_domain_file repositories "$name" state.manifest \
      "$metadata_dir/state.manifest"
    snapshot_download_staged_domain_file repositories "$name" checksums.manifest \
      "$metadata_dir/checksums.manifest" 65536
    repository_verify_state_metadata "$metadata_dir" "$name"
    printf 'repository=%s|%s\n' "$name" "$(encode_field "$REPOSITORY_STATE_SOURCE")" >> "$manifest"
    for encoded in "${REPOSITORY_STATE_INCLUDES[@]}"; do
      printf 'include=%s|%s\n' "$name" "$encoded" >> "$manifest"
    done
    for encoded in "${REPOSITORY_STATE_EXCLUDES[@]}"; do
      printf 'exclude=%s|%s\n' "$name" "$encoded" >> "$manifest"
    done
    ((count += 1))
    rm -rf -- "$metadata_dir"
  done
  printf 'count=%d\n' "$count" >> "$manifest"
  snapshot_upload_manifest repositories "$manifest"
  if (( ${#REQUESTED_REPOSITORIES[@]} == 0 )); then
    repository_prune_cached_mirrors "$cache_root" "${REPOSITORY_NAMES[@]}"
  fi
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

run_backup_domains() {
  local domain handler

  for domain in "${MINT_JELLY_DOMAINS[@]}"; do
    domain_is_selected "$BACKUP_DOMAIN" "$domain" || continue
    handler="backup_$(domain_function_suffix "$domain")_domain"
    declare -F "$handler" >/dev/null || die "Backup handler is missing for domain '$domain'."
    "$handler"
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote) [[ $# -ge 2 ]] || die '--remote requires a name.'; SELECTED_REMOTE="$2"; shift 2 ;;
    --domain) [[ $# -ge 2 ]] || die '--domain requires a value.'; BACKUP_DOMAIN="$2"; shift 2 ;;
    --repository) [[ $# -ge 2 ]] || die '--repository requires a name.'; REQUESTED_REPOSITORIES+=("$2"); shift 2 ;;
    --dry-run) DRY_RUN='true'; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown backup argument: $1" ;;
  esac
done
domain_exists "$BACKUP_DOMAIN" || die "Unknown backup domain: $BACKUP_DOMAIN"
(( ${#REQUESTED_REPOSITORIES[@]} == 0 )) || [[ "$BACKUP_DOMAIN" == 'repositories' ]] \
  || die '--repository is valid only with --domain repositories.'

require_cmd base64
require_cmd hostname
require_cmd rsync
require_initialized_config
local_operation_lock_acquire
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
config_read
declare -A SEEN_REQUESTED_REPOSITORIES=()
for repository in "${REQUESTED_REPOSITORIES[@]}"; do
  validate_safe_name "$repository" && repository_exists "$repository" \
    || die "Repository '$repository' is not configured."
  [[ -z "${SEEN_REQUESTED_REPOSITORIES[$repository]+set}" ]] \
    || die "Repository '$repository' was requested more than once."
  SEEN_REQUESTED_REPOSITORIES["$repository"]=1
done
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
  run_backup_domains
  log 'Backup dry run completed; no remote data was changed.'
  exit 0
fi

remote_open "$SELECTED_REMOTE" "$MACHINE_NAME"
remote_lock_acquire exclusive
if domain_is_selected "$BACKUP_DOMAIN" repositories && [[ "$ACTIVE_REMOTE_TYPE" == 'local' ]]; then
  for repository in "${REPOSITORY_NAMES[@]}"; do
    repository_source="$(realpath -m -- "$(resolve_repository_path "${REPOSITORY_PATH[$repository]}")")"
    repository_destination="$(realpath -m -- "$ACTIVE_HOST_BASE")"
    config_paths_overlap "$repository_source" "$repository_destination" \
      && die "Local backup destination overlaps configured repository '$repository'."
  done
fi
current_snapshot_format=''
current_snapshot_status=0
current_snapshot_format="$(snapshot_current_format)" || current_snapshot_status=$?
if (( current_snapshot_status != 0 && current_snapshot_status != 3 )); then
  die 'Could not inspect the current snapshot format.'
fi
if (( current_snapshot_status == 3 )); then
  [[ "$BACKUP_DOMAIN" == all ]] \
    || die "No valid current snapshot exists. Run a full 'mint-jelly backup' first."
  COPY_CURRENT_SNAPSHOT='false'
elif [[ "$current_snapshot_format" != "$SNAPSHOT_FORMAT" ]]; then
  [[ "$BACKUP_DOMAIN" == 'all' ]] \
    || die "Current snapshot format is $current_snapshot_format. Run a full 'mint-jelly backup' to start format $SNAPSHOT_FORMAT."
  warn "Starting a fresh format-$SNAPSHOT_FORMAT snapshot; older generations will not be copied forward."
  COPY_CURRENT_SNAPSHOT='false'
fi
snapshot_begin "$COPY_CURRENT_SNAPSHOT"
STAGE_STARTED='true'
run_backup_domains
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
