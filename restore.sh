#!/usr/bin/env bash
# Restore one or every domain from a single committed snapshot generation.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/remote.sh"
source "$SCRIPT_DIR/lib/snapshots.sh"
source "$SCRIPT_DIR/lib/installers.sh"
source "$SCRIPT_DIR/lib/software-actions.sh"
source "$SCRIPT_DIR/lib/application-profiles.sh"
source "$SCRIPT_DIR/lib/system-settings.sh"

usage() {
  cat <<EOF
Usage: ${MINT_JELLY_COMMAND:-mint-jelly restore} [--remote NAME] [--source-host HOSTNAME]
       [--domain all|files|software|system-settings] [--dry-run] [--yes]
       [--force] [--include-hardware] [--allow-platform-mismatch]
       [--allow-weak-verification]

--yes confirms the restore. --force permits overwriting existing file and
application configuration paths. Hardware-bound profiles restore automatically
on matching hardware and require --include-hardware on different hardware.
EOF
}

SELECTED_REMOTE=''
SOURCE_HOST=''
RESTORE_DOMAIN='all'
DRY_RUN='false'
ASSUME_YES='false'
FORCE='false'
INCLUDE_HARDWARE='false'
ALLOW_PLATFORM_MISMATCH='false'
ALLOW_WEAK='false'
LIST_ONLY='false'
TEMP_FILES=()
FILES_MANIFEST=''
SOFTWARE_MANIFEST=''
SETTINGS_MANIFEST=''
RESTORE_FILE_PATHS=()
RESTORE_APT=()
RESTORE_INSTALLERS=()
RESTORE_INSTALLER_OPTIONS=()
RESTORE_FLATPAKS=()
RESTORE_APPLICATIONS=()
RESTORE_APPLICATION_PATHS=()
RESTORE_SETTING_PROFILES=()
RESTORE_SETTING_VALUES=()
RESTORE_SETTING_ASSETS=()
RECORDED_HARDWARE=''
RECORDED_OS_ID=''
RECORDED_OS_VERSION=''
RECORDED_ARCHITECTURE=''
RECORDED_HOSTNAME=''

cleanup() {
  local file
  for file in "${TEMP_FILES[@]}"; do rm -f -- "$file"; done
  remote_close
  local_operation_lock_release
}

decode_field() {
  local encoded="$1" decoded
  [[ "$encoded" =~ ^[A-Za-z0-9+/]*={0,2}$ ]] || return 1
  decoded="$(printf '%s' "$encoded" | base64 --decode 2>/dev/null)" || return 1
  [[ "$decoded" != *$'\n'* && "$decoded" != *$'\r'* ]] || return 1
  printf '%s' "$decoded"
}

read_domain_manifest() {
  local domain="$1" variable="$2" file
  file="$(mktemp "$MINT_JELLY_CONFIG_DIR/.restore-${domain}.XXXXXX")"
  TEMP_FILES+=("$file")
  snapshot_read_manifest "$domain" > "$file" \
    || die "Snapshot $SNAPSHOT_ID does not contain the '$domain' domain."
  printf -v "$variable" '%s' "$file"
}

record_common_field() {
  local key="$1" value="$2"
  case "$key" in
    hostname)
      if [[ -z "$RECORDED_HOSTNAME" ]]; then RECORDED_HOSTNAME="$value"; elif [[ "$RECORDED_HOSTNAME" != "$value" ]]; then die 'Snapshot domains disagree about their source hostname.'; fi
      ;;
    hardware)
      if [[ -z "$RECORDED_HARDWARE" ]]; then RECORDED_HARDWARE="$value"; elif [[ "$RECORDED_HARDWARE" != "$value" ]]; then die 'Snapshot domains disagree about their hardware identity.'; fi
      ;;
    os_id)
      if [[ -z "$RECORDED_OS_ID" ]]; then RECORDED_OS_ID="$value"; elif [[ "$RECORDED_OS_ID" != "$value" ]]; then die 'Snapshot domains disagree about their operating system.'; fi
      ;;
    os_version)
      if [[ -z "$RECORDED_OS_VERSION" ]]; then RECORDED_OS_VERSION="$value"; elif [[ "$RECORDED_OS_VERSION" != "$value" ]]; then die 'Snapshot domains disagree about their operating-system version.'; fi
      ;;
    architecture)
      if [[ -z "$RECORDED_ARCHITECTURE" ]]; then RECORDED_ARCHITECTURE="$value"; elif [[ "$RECORDED_ARCHITECTURE" != "$value" ]]; then die 'Snapshot domains disagree about their architecture.'; fi
      ;;
  esac
}

parse_files_manifest() {
  local raw key value path version='' domain=''
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    [[ "$raw" == *=* ]] || die 'Invalid files manifest line.'
    key="${raw%%=*}"; value="${raw#*=}"
    case "$key" in
      version) version="$value" ;;
      domain) domain="$value" ;;
      path)
        path="$(decode_field "$value")" || die 'Files manifest contains an invalid encoded path.'
        validate_absolute_path "$path" || die "Files manifest contains an unsafe path: $path"
        RESTORE_FILE_PATHS+=("$path")
        ;;
      created_at|count) ;;
      hostname|hardware|os_id|os_version|architecture) record_common_field "$key" "$value" ;;
      *) die "Files manifest contains unknown key '$key'." ;;
    esac
  done < "$FILES_MANIFEST"
  [[ "$version" == '2' && "$domain" == 'files' ]] || die 'Files manifest has an incompatible format.'
}

parse_software_manifest() {
  local raw key value profile encoded path version='' domain=''
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    [[ "$raw" == *=* ]] || die 'Invalid software manifest line.'
    key="${raw%%=*}"; value="${raw#*=}"
    case "$key" in
      version) version="$value" ;;
      domain) domain="$value" ;;
      apt_package) validate_apt_package_name "$value" || die "Invalid APT package in snapshot: $value"; RESTORE_APT+=("$value") ;;
      installer) validate_safe_name "$value" || die "Invalid installer in snapshot: $value"; RESTORE_INSTALLERS+=("$value") ;;
      installer_option) [[ "$value" =~ ^[A-Za-z0-9._-]+:[A-Za-z0-9._-]+$ ]] || die "Invalid installer option in snapshot: $value"; RESTORE_INSTALLER_OPTIONS+=("$value") ;;
      flatpak_app) validate_flatpak_app_spec "$value" || die "Invalid Flatpak app in snapshot: $value"; RESTORE_FLATPAKS+=("$value") ;;
      application) application_profile_exists "$value" || die "Unknown application profile in snapshot: $value"; RESTORE_APPLICATIONS+=("$value") ;;
      application_path)
        profile="${value%%|*}"; encoded="${value#*|}"
        application_profile_exists "$profile" || die "Unknown application profile in snapshot: $profile"
        path="$(decode_field "$encoded")" || die 'Software manifest contains an invalid encoded path.'
        validate_absolute_path "$path" || die "Software manifest contains an unsafe path: $path"
        RESTORE_APPLICATION_PATHS+=("$profile|$path")
        ;;
      created_at|application_path_count) ;;
      hostname|hardware|os_id|os_version|architecture) record_common_field "$key" "$value" ;;
      *) die "Software manifest contains unknown key '$key'." ;;
    esac
  done < "$SOFTWARE_MANIFEST"
  [[ "$version" == '2' && "$domain" == 'software' ]] || die 'Software manifest has an incompatible format.'
}

parse_settings_manifest() {
  local raw key value profile class remainder schema setting encoded path version='' domain=''
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    [[ "$raw" == *=* ]] || die 'Invalid system-settings manifest line.'
    key="${raw%%=*}"; value="${raw#*=}"
    case "$key" in
      version) version="$value" ;;
      domain) domain="$value" ;;
      profile)
        profile="${value%%|*}"; class="${value#*|}"
        system_setting_exists "$profile" || die "Unknown settings profile in snapshot: $profile"
        [[ "$class" == portable || "$class" == hardware ]] || die "Invalid settings class: $class"
        RESTORE_SETTING_PROFILES+=("$profile|$class")
        ;;
      value)
        profile="${value%%|*}"; remainder="${value#*|}"
        schema="${remainder%%|*}"; remainder="${remainder#*|}"
        setting="${remainder%%|*}"; encoded="${remainder#*|}"
        system_setting_exists "$profile" || die "Unknown settings profile in value: $profile"
        [[ "$schema" =~ ^[A-Za-z0-9._-]+$ && "$setting" =~ ^[A-Za-z0-9._-]+$ ]] || die 'Unsafe GSettings identity in snapshot.'
        RESTORE_SETTING_VALUES+=("$profile|$schema|$setting|$encoded")
        ;;
      asset)
        profile="${value%%|*}"; encoded="${value#*|}"
        path="$(decode_field "$encoded")" || die 'Settings manifest contains an invalid encoded path.'
        system_setting_exists "$profile" || die "Unknown settings profile for asset: $profile"
        validate_absolute_path "$path" || die "Settings manifest contains an unsafe path: $path"
        RESTORE_SETTING_ASSETS+=("$profile|$path")
        ;;
      created_at|value_count) ;;
      hostname|hardware|os_id|os_version|architecture) record_common_field "$key" "$value" ;;
      *) die "System-settings manifest contains unknown key '$key'." ;;
    esac
  done < "$SETTINGS_MANIFEST"
  [[ "$version" == '2' && "$domain" == 'system-settings' ]] || die 'System-settings manifest has an incompatible format.'
}

profile_is_skipped_for_hardware() {
  local profile="$1" class="${SYSTEM_SETTING_CLASS[$1]}"
  [[ "$class" == 'hardware' && "$RECORDED_HARDWARE" != "$(system_hardware_fingerprint)" \
    && "$INCLUDE_HARDWARE" != 'true' ]]
}

print_plan() {
  local value profile path
  printf 'Snapshot: %s/%s (%s)\n' "$SELECTED_REMOTE" "$SOURCE_HOST" "$SNAPSHOT_ID"
  if (( ${#RESTORE_FILE_PATHS[@]} )); then
    printf 'Files:\n'; printf '  %s\n' "${RESTORE_FILE_PATHS[@]}"
  fi
  if (( ${#RESTORE_APT[@]} + ${#RESTORE_FLATPAKS[@]} + ${#RESTORE_INSTALLERS[@]} )); then
    printf 'Software:\n'
    for value in "${RESTORE_APT[@]}"; do printf '  apt: %s\n' "$value"; done
    for value in "${RESTORE_FLATPAKS[@]}"; do printf '  flatpak: %s\n' "$value"; done
    for value in "${RESTORE_INSTALLERS[@]}"; do printf '  installer: %s\n' "$value"; done
    for value in "${RESTORE_APPLICATIONS[@]}"; do printf '  config: %s\n' "$value"; done
  fi
  if (( ${#RESTORE_SETTING_PROFILES[@]} )); then
    printf 'System settings:\n'
    for value in "${RESTORE_SETTING_PROFILES[@]}"; do
      profile="${value%%|*}"
      if profile_is_skipped_for_hardware "$profile"; then
        printf '  %s [hardware mismatch: skipped]\n' "${SYSTEM_SETTING_NAME[$profile]}"
      else
        printf '  %s\n' "${SYSTEM_SETTING_NAME[$profile]}"
      fi
    done
  fi
}

validate_platform() {
  local current_id='unknown' current_version='unknown' current_arch
  if [[ -r /etc/os-release ]]; then source /etc/os-release; current_id="${ID:-unknown}"; current_version="${VERSION_ID:-unknown}"; fi
  current_arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  if [[ "$RECORDED_OS_ID" == "$current_id" && "$RECORDED_OS_VERSION" == "$current_version" \
    && "$RECORDED_ARCHITECTURE" == "$current_arch" ]]; then return 0; fi
  warn "Snapshot platform is $RECORDED_OS_ID $RECORDED_OS_VERSION ($RECORDED_ARCHITECTURE); current platform is $current_id $current_version ($current_arch)."
  [[ "$ALLOW_PLATFORM_MISMATCH" == 'true' ]] \
    || die 'Refusing cross-platform restore. Review the plan and use --allow-platform-mismatch if intentional.'
}

confirm_restore() {
  local answer
  [[ "$DRY_RUN" == 'true' ]] && return 0
  [[ "$ASSUME_YES" == 'true' ]] && return 0
  is_interactive || die 'Restore requires confirmation; use --yes after reviewing the plan.'
  printf 'Continue with this restore? [y/N]: '
  IFS= read -r answer
  [[ "${answer,,}" == y || "${answer,,}" == yes ]] || die 'Restore cancelled.'
}

should_overwrite_path() {
  local path="$1" answer
  [[ ! -e "$path" && ! -L "$path" ]] && return 0
  if [[ "$DRY_RUN" == 'true' ]]; then
    log "Would overwrite existing path: $path"
    return 0
  fi
  [[ "$FORCE" == 'true' ]] && return 0
  if ! is_interactive; then
    warn "Skipping existing path without --force: $path"
    return 1
  fi
  printf 'Overwrite files at existing path %s? [y/N]: ' "$path"
  IFS= read -r answer
  [[ "${answer,,}" == y || "${answer,,}" == yes ]]
}

restore_software_plan() {
  local installer
  APT_PACKAGES=("${RESTORE_APT[@]}")
  INSTALLERS=("${RESTORE_INSTALLERS[@]}")
  INSTALLER_OPTION_SELECTIONS=("${RESTORE_INSTALLER_OPTIONS[@]}")
  FLATPAK_APPS=("${RESTORE_FLATPAKS[@]}")
  APPLICATIONS=("${RESTORE_APPLICATIONS[@]}")
  [[ "$DRY_RUN" == 'true' ]] && return 0
  config_write
  (( EUID != 0 )) || die 'Run Mint Jelly as your desktop user, not as root.'
  if (( ${#RESTORE_APT[@]} )); then require_cmd sudo; require_cmd apt-get; require_cmd dpkg-query; software_install_apt_packages "$ASSUME_YES" "${RESTORE_APT[@]}"; fi
  if (( ${#RESTORE_FLATPAKS[@]} )); then require_cmd flatpak; software_install_flatpaks "$ASSUME_YES" "${RESTORE_FLATPAKS[@]}"; fi
  if (( ${#RESTORE_INSTALLERS[@]} )); then
    require_cmd dpkg
    load_installers
    require_configured_installers_available
    require_configured_installer_options_available
    for installer in "${RESTORE_INSTALLERS[@]}"; do
      software_run_installer_action "$installer" install "$ALLOW_WEAK" "$ASSUME_YES"
    done
  fi
}

restore_path_array() {
  local domain="$1" value profile path
  local -A checked_profiles=()
  shift
  SNAPSHOT_RESTORE_DOMAIN="$domain"
  for value in "$@"; do
    if [[ "$value" == *'|'* ]]; then profile="${value%%|*}"; path="${value#*|}"; else profile=''; path="$value"; fi
    if [[ "$domain" == software && -n "$profile" && -z "${checked_profiles[$profile]+set}" ]]; then
      application_profile_preflight_restore "$profile"
      checked_profiles[$profile]=1
    fi
    if [[ -n "$profile" && "$domain" == system-settings ]] \
      && profile_is_skipped_for_hardware "$profile"; then
      continue
    fi
    should_overwrite_path "$path" || continue
    log "Restoring $path"
    snapshot_restore_absolute "$path" "$DRY_RUN"
  done
}

apply_system_settings() {
  local entry profile remainder schema key encoded value
  [[ "$DRY_RUN" == 'false' ]] || return 0
  require_cmd gsettings
  for entry in "${RESTORE_SETTING_VALUES[@]}"; do
    profile="${entry%%|*}"; remainder="${entry#*|}"
    profile_is_skipped_for_hardware "$profile" && continue
    schema="${remainder%%|*}"; remainder="${remainder#*|}"
    key="${remainder%%|*}"; encoded="${remainder#*|}"
    value="$(decode_field "$encoded")" || die "Invalid encoded GSettings value for $schema $key."
    if ! gsettings list-schemas | grep -Fxq "$schema" || ! gsettings list-keys "$schema" | grep -Fxq "$key"; then
      warn "Skipping unavailable setting: $schema $key"
      continue
    fi
    gsettings set "$schema" "$key" "$value" \
      || warn "Could not apply setting: $schema $key"
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote) [[ $# -ge 2 ]] || die '--remote requires a name.'; SELECTED_REMOTE="$2"; shift 2 ;;
    --source-host) [[ $# -ge 2 ]] || die '--source-host requires a hostname.'; SOURCE_HOST="$2"; shift 2 ;;
    --domain) [[ $# -ge 2 ]] || die '--domain requires a value.'; RESTORE_DOMAIN="$2"; shift 2 ;;
    --dry-run) DRY_RUN='true'; shift ;;
    --yes) ASSUME_YES='true'; shift ;;
    --force) FORCE='true'; shift ;;
    --include-hardware) INCLUDE_HARDWARE='true'; shift ;;
    --allow-platform-mismatch) ALLOW_PLATFORM_MISMATCH='true'; shift ;;
    --allow-weak-verification) ALLOW_WEAK='true'; shift ;;
    --list) LIST_ONLY='true'; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown restore argument: $1" ;;
  esac
done
case "$RESTORE_DOMAIN" in all|files|software|system-settings) ;; *) die "Unknown restore domain: $RESTORE_DOMAIN" ;; esac
require_cmd base64
require_cmd hostname
require_initialized_config
local_operation_lock_acquire
trap cleanup EXIT
config_read
[[ -n "$SELECTED_REMOTE" ]] || SELECTED_REMOTE="$DEFAULT_REMOTE"
[[ -n "$SELECTED_REMOTE" ]] || die 'No default remote is configured.'
remote_exists "$SELECTED_REMOTE" || die "Unknown backup remote: $SELECTED_REMOTE"
[[ -n "$SOURCE_HOST" ]] || SOURCE_HOST="$(hostname)"
validate_safe_name "$SOURCE_HOST" || die "Unsafe source hostname: $SOURCE_HOST"
remote_open "$SELECTED_REMOTE" "$SOURCE_HOST" read
remote_lock_acquire shared
snapshot_select_current
case "$RESTORE_DOMAIN" in all|files) read_domain_manifest files FILES_MANIFEST; parse_files_manifest ;; esac
case "$RESTORE_DOMAIN" in all|software) read_domain_manifest software SOFTWARE_MANIFEST; parse_software_manifest ;; esac
case "$RESTORE_DOMAIN" in all|system-settings) read_domain_manifest system-settings SETTINGS_MANIFEST; parse_settings_manifest ;; esac
[[ "$RECORDED_HOSTNAME" == "$SOURCE_HOST" ]] \
  || die "Snapshot hostname '$RECORDED_HOSTNAME' does not match requested source host '$SOURCE_HOST'."
print_plan
[[ "$LIST_ONLY" == 'false' ]] || exit 0
validate_platform
confirm_restore
case "$RESTORE_DOMAIN" in all|software) restore_software_plan ;; esac
case "$RESTORE_DOMAIN" in all|files)
  FILE_SPECS=("${RESTORE_FILE_PATHS[@]}")
  [[ "$DRY_RUN" == 'true' ]] || config_write
  restore_path_array files "${RESTORE_FILE_PATHS[@]}"
  ;;
esac
case "$RESTORE_DOMAIN" in all|software) restore_path_array software "${RESTORE_APPLICATION_PATHS[@]}" ;; esac
case "$RESTORE_DOMAIN" in all|system-settings)
  SYSTEM_SETTINGS=(); for entry in "${RESTORE_SETTING_PROFILES[@]}"; do SYSTEM_SETTINGS+=("${entry%%|*}"); done
  [[ "$DRY_RUN" == 'true' ]] || config_write
  restore_path_array system-settings "${RESTORE_SETTING_ASSETS[@]}"
  apply_system_settings
  ;;
esac
remote_lock_release || die 'Could not release the remote operation lock.'
remote_close
local_operation_lock_release
trap - EXIT
[[ "$DRY_RUN" == 'true' ]] && log 'Restore dry run completed; no local data was changed.' \
  || log "Restore from snapshot $SNAPSHOT_ID completed successfully."
