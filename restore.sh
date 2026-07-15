#!/usr/bin/env bash
# Restore one or every domain from a single committed snapshot generation.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/domains.sh"
source "$SCRIPT_DIR/lib/remote.sh"
source "$SCRIPT_DIR/lib/snapshots.sh"
source "$SCRIPT_DIR/lib/installers.sh"
source "$SCRIPT_DIR/lib/software-actions.sh"
source "$SCRIPT_DIR/lib/application-profiles.sh"
source "$SCRIPT_DIR/lib/repositories.sh"
source "$SCRIPT_DIR/lib/system-settings.sh"

usage() {
  cat <<EOF
Usage: ${MINT_JELLY_COMMAND:-mint-jelly restore} [--remote NAME] [--source-host HOSTNAME]
       [--domain all|$(domain_list_pipe_separated)] [--repository NAME]
       [--dry-run] [--yes]
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
TEMP_DIRS=()
FILES_MANIFEST=''
SOFTWARE_MANIFEST=''
SETTINGS_MANIFEST=''
REPOSITORIES_MANIFEST=''
SNAPSHOT_MANIFEST=''
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
RESTORE_REPOSITORIES=()
RESTORE_REPOSITORY_INCLUDES=()
RESTORE_REPOSITORY_EXCLUDES=()
REQUESTED_REPOSITORIES=()
REPOSITORY_SWAP_DESTINATION=''
REPOSITORY_SWAP_PREVIOUS=''
REPOSITORY_SWAP_RECOVERY_ROOT=''
RESTORED_CONFIGURATION_PREPARED='false'
RECORDED_HOSTNAME=''
declare -Ag RECORDED_DOMAIN_HARDWARE=()
declare -Ag RECORDED_DOMAIN_OS_ID=()
declare -Ag RECORDED_DOMAIN_OS_VERSION=()
declare -Ag RECORDED_DOMAIN_ARCHITECTURE=()

cleanup() {
  local file directory preserved_recovery_root=''
  if [[ -n "$REPOSITORY_SWAP_PREVIOUS" && ( -e "$REPOSITORY_SWAP_PREVIOUS" || -L "$REPOSITORY_SWAP_PREVIOUS" ) \
    && ! -e "$REPOSITORY_SWAP_DESTINATION" && ! -L "$REPOSITORY_SWAP_DESTINATION" ]]; then
    mv -T -n -- "$REPOSITORY_SWAP_PREVIOUS" "$REPOSITORY_SWAP_DESTINATION" 2>/dev/null || true
    if [[ -e "$REPOSITORY_SWAP_PREVIOUS" || -L "$REPOSITORY_SWAP_PREVIOUS" ]]; then
      preserved_recovery_root="$REPOSITORY_SWAP_RECOVERY_ROOT"
      warn "Automatic repository rollback failed; original data is preserved at $REPOSITORY_SWAP_PREVIOUS"
    fi
  fi
  for file in "${TEMP_FILES[@]}"; do rm -f -- "$file"; done
  for directory in "${TEMP_DIRS[@]}"; do
    [[ -z "$preserved_recovery_root" || "$directory" != "$preserved_recovery_root" ]] \
      || continue
    rm -rf -- "$directory"
  done
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
  local manifest_domain="$1" key="$2" value="$3" map_name current

  case "$key" in
    hostname)
      [[ "$manifest_domain" != snapshot ]] || RECORDED_HOSTNAME="$value"
      ;;
    hardware) map_name=RECORDED_DOMAIN_HARDWARE ;;
    os_id) map_name=RECORDED_DOMAIN_OS_ID ;;
    os_version) map_name=RECORDED_DOMAIN_OS_VERSION ;;
    architecture) map_name=RECORDED_DOMAIN_ARCHITECTURE ;;
    *) return 0 ;;
  esac
  [[ "$key" != hostname ]] || return 0
  local -n map_ref="$map_name"
  current="${map_ref[$manifest_domain]-}"
  [[ -z "$current" || "$current" == "$value" ]] \
    || die "The $manifest_domain manifest repeats conflicting $key metadata."
  map_ref["$manifest_domain"]="$value"
}

parse_snapshot_manifest() {
  local raw key value version='' domain=''
  local -A seen=()

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    [[ "$raw" == *=* ]] || die 'Invalid root snapshot manifest line.'
    key="${raw%%=*}"; value="${raw#*=}"
    [[ -z "${seen[$key]+set}" ]] || die "Root snapshot manifest repeats '$key'."
    seen["$key"]=1
    case "$key" in
      version) version="$value" ;;
      domain) domain="$value" ;;
      hostname|hardware|os_id|os_version|architecture) record_common_field snapshot "$key" "$value" ;;
      created_at|updated_domain) ;;
      *) die "Root snapshot manifest contains unknown key '$key'." ;;
    esac
  done < "$SNAPSHOT_MANIFEST"
  [[ "$version" == "$SNAPSHOT_FORMAT" && "$domain" == snapshot ]] \
    || die 'Root snapshot manifest has an incompatible format.'
  validate_safe_name "$RECORDED_HOSTNAME" || die 'Root snapshot manifest has an unsafe hostname.'
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
      hostname|hardware|os_id|os_version|architecture) record_common_field files "$key" "$value" ;;
      *) die "Files manifest contains unknown key '$key'." ;;
    esac
  done < "$FILES_MANIFEST"
  [[ "$version" == "$SNAPSHOT_FORMAT" && "$domain" == 'files' ]] || die 'Files manifest has an incompatible format.'
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
      hostname|hardware|os_id|os_version|architecture) record_common_field software "$key" "$value" ;;
      *) die "Software manifest contains unknown key '$key'." ;;
    esac
  done < "$SOFTWARE_MANIFEST"
  [[ "$version" == "$SNAPSHOT_FORMAT" && "$domain" == 'software' ]] || die 'Software manifest has an incompatible format.'
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
      hostname|hardware|os_id|os_version|architecture) record_common_field system-settings "$key" "$value" ;;
      *) die "System-settings manifest contains unknown key '$key'." ;;
    esac
  done < "$SETTINGS_MANIFEST"
  [[ "$version" == "$SNAPSHOT_FORMAT" && "$domain" == 'system-settings' ]] || die 'System-settings manifest has an incompatible format.'
}

repository_is_requested() {
  local wanted="$1" requested

  (( ${#REQUESTED_REPOSITORIES[@]} == 0 )) && return 0
  for requested in "${REQUESTED_REPOSITORIES[@]}"; do
    [[ "$requested" == "$wanted" ]] && return 0
  done
  return 1
}

parse_repositories_manifest() {
  local raw key value name encoded path version='' domain='' declared_count='' actual_count=0
  local entry other other_name other_path
  local -A seen=() requested_seen=() singleton=() seen_includes=() seen_excludes=()

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    [[ "$raw" == *=* ]] || die 'Repositories manifest contains an invalid line.'
    key="${raw%%=*}"
    value="${raw#*=}"
    case "$key" in
      version|domain|count|created_at|hostname|hardware|os_id|os_version|architecture)
        [[ -z "${singleton[$key]+set}" ]] || die "Repositories manifest repeats '$key'."
        singleton["$key"]=1
        ;;
    esac
    case "$key" in
      version) version="$value" ;;
      domain) domain="$value" ;;
      repository)
        name="${value%%|*}"
        encoded="${value#*|}"
        [[ "$value" == *'|'* ]] && validate_safe_name "$name" \
          || die 'Repositories manifest contains an invalid repository identity.'
        [[ -z "${seen[$name]+set}" ]] \
          || die "Repositories manifest lists '$name' more than once."
        path="$(decode_field "$encoded")" \
          || die "Repository '$name' has an invalid encoded restore path."
        validate_absolute_path "$path" \
          || die "Repository '$name' has an unsafe restore path: $path"
        seen["$name"]=1
        RESTORE_REPOSITORIES+=("$name|$encoded")
        ((actual_count += 1))
        ;;
      include|exclude)
        name="${value%%|*}"
        encoded="${value#*|}"
        [[ "$value" == *'|'* ]] && validate_safe_name "$name" \
          || die "Repositories manifest contains an invalid $key identity."
        path="$(decode_field "$encoded")" \
          || die "Repository '$name' has an invalid encoded $key path."
        validate_repository_relative_path "$path" \
          || die "Repository '$name' has an unsafe $key path: $path"
        if [[ "$key" == 'include' ]]; then
          [[ -z "${seen_includes["$name|$path"]+set}" ]] \
            || die "Repository '$name' include is listed more than once: $path"
          seen_includes["$name|$path"]=1
          RESTORE_REPOSITORY_INCLUDES+=("$name|$encoded")
        else
          [[ -z "${seen_excludes["$name|$path"]+set}" ]] \
            || die "Repository '$name' exclude is listed more than once: $path"
          seen_excludes["$name|$path"]=1
          RESTORE_REPOSITORY_EXCLUDES+=("$name|$encoded")
        fi
        ;;
      count) declared_count="$value" ;;
      created_at) ;;
      hostname|hardware|os_id|os_version|architecture) record_common_field repositories "$key" "$value" ;;
      *) die "Repositories manifest contains unknown key '$key'." ;;
    esac
  done < "$REPOSITORIES_MANIFEST"

  [[ "$version" == "$SNAPSHOT_FORMAT" && "$domain" == 'repositories' ]] \
    || die 'Repositories manifest has an incompatible format.'
  [[ "$declared_count" =~ ^(0|[1-9][0-9]*)$ && "$declared_count" -eq "$actual_count" ]] \
    || die 'Repositories manifest count does not match its entries.'
  for entry in "${RESTORE_REPOSITORY_INCLUDES[@]}" "${RESTORE_REPOSITORY_EXCLUDES[@]}"; do
    name="${entry%%|*}"
    [[ -n "${seen[$name]+set}" ]] \
      || die "Repositories manifest has a rule for unknown repository '$name'."
  done
  for entry in "${RESTORE_REPOSITORY_INCLUDES[@]}"; do
    name="${entry%%|*}"
    path="$(decode_field "${entry#*|}")" || die "Repository '$name' has an invalid include path."
    for other in "${RESTORE_REPOSITORY_EXCLUDES[@]}"; do
      other_name="${other%%|*}"
      [[ "$other_name" == "$name" ]] || continue
      other_path="$(decode_field "${other#*|}")" || die "Repository '$name' has an invalid exclude path."
      config_repository_rules_overlap "$path" "$other_path" \
        && die "Repository '$name' has conflicting include/exclude paths: $path and $other_path"
    done
  done
  for name in "${REQUESTED_REPOSITORIES[@]}"; do
    validate_safe_name "$name" || die "Invalid requested repository name: $name"
    [[ -n "${seen[$name]+set}" ]] \
      || die "Repository '$name' is not present in snapshot $SNAPSHOT_ID."
    [[ -z "${requested_seen[$name]+set}" ]] \
      || die "Repository '$name' was requested more than once."
    requested_seen["$name"]=1
  done
}

load_files_domain() {
  read_domain_manifest files FILES_MANIFEST
  parse_files_manifest
}

load_snapshot_metadata() {
  read_domain_manifest snapshot SNAPSHOT_MANIFEST
  parse_snapshot_manifest
}

load_software_domain() {
  read_domain_manifest software SOFTWARE_MANIFEST
  parse_software_manifest
}

load_repositories_domain() {
  read_domain_manifest repositories REPOSITORIES_MANIFEST
  parse_repositories_manifest
}

load_system_settings_domain() {
  read_domain_manifest system-settings SETTINGS_MANIFEST
  parse_settings_manifest
}

load_selected_domains() {
  local domain handler

  for domain in "${MINT_JELLY_DOMAINS[@]}"; do
    domain_is_selected "$RESTORE_DOMAIN" "$domain" || continue
    handler="load_$(domain_function_suffix "$domain")_domain"
    declare -F "$handler" >/dev/null || die "Restore loader is missing for domain '$domain'."
    "$handler"
  done
}

profile_is_skipped_for_hardware() {
  local profile="$1" class="${SYSTEM_SETTING_CLASS[$1]}"
  [[ "$class" == 'hardware' \
    && "${RECORDED_DOMAIN_HARDWARE[system-settings]-unknown}" != "$(system_hardware_fingerprint)" \
    && "$INCLUDE_HARDWARE" != 'true' ]]
}

print_plan() {
  local value profile path name encoded
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
  if (( ${#RESTORE_REPOSITORIES[@]} )); then
    printf 'Repositories:\n'
    for value in "${RESTORE_REPOSITORIES[@]}"; do
      name="${value%%|*}"
      repository_is_requested "$name" || continue
      encoded="${value#*|}"
      path="$(decode_field "$encoded")" \
        || die "Repository '$name' has an invalid encoded restore path."
      printf '  %s: %s\n' "$name" "$path"
    done
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
  local current_id='unknown' current_version='unknown' current_arch domain label mismatch='false'
  local recorded_id recorded_version recorded_arch
  if [[ -r /etc/os-release ]]; then source /etc/os-release; current_id="${ID:-unknown}"; current_version="${VERSION_ID:-unknown}"; fi
  current_arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  for domain in software system-settings; do
    domain_is_selected "$RESTORE_DOMAIN" "$domain" || continue
    recorded_id="${RECORDED_DOMAIN_OS_ID[$domain]-unknown}"
    recorded_version="${RECORDED_DOMAIN_OS_VERSION[$domain]-unknown}"
    recorded_arch="${RECORDED_DOMAIN_ARCHITECTURE[$domain]-unknown}"
    [[ "$recorded_id" != "$current_id" || "$recorded_version" != "$current_version" \
      || "$recorded_arch" != "$current_arch" ]] || continue
    label="$domain"
    warn "$label snapshot platform is $recorded_id $recorded_version ($recorded_arch); current platform is $current_id $current_version ($current_arch)."
    mismatch='true'
  done
  [[ "$mismatch" != true || "$ALLOW_PLATFORM_MISMATCH" == true ]] \
    || die 'Refusing cross-platform software/settings restore. Review the plan and use --allow-platform-mismatch if intentional.'
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

repository_manifest_path() {
  local wanted="$1" entry

  for entry in "${RESTORE_REPOSITORIES[@]}"; do
    [[ "${entry%%|*}" == "$wanted" ]] || continue
    decode_field "${entry#*|}"
    return
  done
  return 1
}

prepare_repository_configuration() {
  local entry name path encoded configured_path rule_name rule_path

  if (( ${#REQUESTED_REPOSITORIES[@]} == 0 )); then
    REPOSITORY_NAMES=()
    REPOSITORY_PATH=()
    REPOSITORY_INCLUDES=()
    REPOSITORY_EXCLUDES=()
  else
    for name in "${REQUESTED_REPOSITORIES[@]}"; do
      repository_exists "$name" && config_remove_repository "$name"
    done
  fi

  for entry in "${RESTORE_REPOSITORIES[@]}"; do
    name="${entry%%|*}"
    repository_is_requested "$name" || continue
    encoded="${entry#*|}"
    path="$(decode_field "$encoded")" \
      || die "Repository '$name' has an invalid encoded restore path."
    configured_path="$path"
    if [[ "$path" == "$HOME/"* ]]; then configured_path="~/${path#"$HOME/"}"; fi
    config_add_repository_name "$name"
    REPOSITORY_PATH["$name"]="$configured_path"
  done
  for entry in "${RESTORE_REPOSITORY_INCLUDES[@]}"; do
    rule_name="${entry%%|*}"
    repository_is_requested "$rule_name" || continue
    rule_path="$(decode_field "${entry#*|}")" \
      || die "Repository '$rule_name' has an invalid encoded include path."
    config_repository_add_include "$rule_name" "$rule_path"
  done
  for entry in "${RESTORE_REPOSITORY_EXCLUDES[@]}"; do
    rule_name="${entry%%|*}"
    repository_is_requested "$rule_name" || continue
    rule_path="$(decode_field "${entry#*|}")" \
      || die "Repository '$rule_name' has an invalid encoded exclude path."
    config_repository_add_exclude "$rule_name" "$rule_path"
  done
}

prepare_restored_configuration() {
  local entry

  if domain_is_selected "$RESTORE_DOMAIN" software; then
    APT_PACKAGES=("${RESTORE_APT[@]}")
    INSTALLERS=("${RESTORE_INSTALLERS[@]}")
    INSTALLER_OPTION_SELECTIONS=("${RESTORE_INSTALLER_OPTIONS[@]}")
    FLATPAK_APPS=("${RESTORE_FLATPAKS[@]}")
    APPLICATIONS=("${RESTORE_APPLICATIONS[@]}")
  fi
  if domain_is_selected "$RESTORE_DOMAIN" files; then
    FILE_SPECS=("${RESTORE_FILE_PATHS[@]}")
  fi
  if domain_is_selected "$RESTORE_DOMAIN" repositories; then
    prepare_repository_configuration
  fi
  if domain_is_selected "$RESTORE_DOMAIN" system-settings; then
    SYSTEM_SETTINGS=()
    for entry in "${RESTORE_SETTING_PROFILES[@]}"; do
      SYSTEM_SETTINGS+=("${entry%%|*}")
    done
  fi
  config_validate
  RESTORED_CONFIGURATION_PREPARED='true'
}

replace_repository_destination() {
  local staged="$1" destination="$2" parent previous previous_root

  parent="$(dirname -- "$destination")"
  if [[ ! -e "$destination" && ! -L "$destination" ]]; then
    mv -T -n -- "$staged" "$destination" \
      || die "Could not move restored repository into place: $destination"
    [[ ! -e "$staged" && ! -L "$staged" ]] \
      || die "Repository destination appeared during restore; staged data remains at $staged"
    return 0
  fi

  previous_root="$(mktemp -d "$parent/.mint-jelly-previous.XXXXXX")"
  TEMP_DIRS+=("$previous_root")
  previous="$previous_root/original"
  REPOSITORY_SWAP_DESTINATION="$destination"
  REPOSITORY_SWAP_PREVIOUS="$previous"
  REPOSITORY_SWAP_RECOVERY_ROOT="$previous_root"
  mv -T -- "$destination" "$previous" \
    || die "Could not stage existing repository for replacement: $destination"
  if ! mv -T -n -- "$staged" "$destination" \
    || [[ -e "$staged" || -L "$staged" ]]; then
    if mv -T -n -- "$previous" "$destination" \
      && [[ ! -e "$previous" && ! -L "$previous" ]]; then
      rm -rf -- "$previous_root"
      REPOSITORY_SWAP_DESTINATION=''
      REPOSITORY_SWAP_PREVIOUS=''
      REPOSITORY_SWAP_RECOVERY_ROOT=''
      die "Could not move restored repository into place: $destination"
    fi
    die "Repository replacement and rollback both failed; original data is preserved at $previous"
  fi
  rm -rf -- "$previous_root"
  REPOSITORY_SWAP_DESTINATION=''
  REPOSITORY_SWAP_PREVIOUS=''
  REPOSITORY_SWAP_RECOVERY_ROOT=''
}

repository_require_safe_destination_parent() {
  local destination="$1" parent current='/' component
  local -a components=()

  validate_absolute_path "$destination" || die "Unsafe repository destination: $destination"
  parent="$(dirname -- "$destination")"
  IFS='/' read -r -a components <<< "${parent#/}"
  for component in "${components[@]}"; do
    [[ -n "$component" ]] || continue
    current="${current%/}/$component"
    [[ ! -L "$current" ]] || die "Repository destination traverses a symbolic link: $current"
    [[ ! -e "$current" || -d "$current" ]] \
      || die "Repository destination parent is not a directory: $current"
  done
  if [[ "$ACTIVE_REMOTE_TYPE" == local ]]; then
    config_paths_overlap "$destination" "$ACTIVE_HOST_BASE" \
      && die "Repository destination overlaps the active local backup: $destination"
  fi
  return 0
}

repository_artifact_matches_manifest() {
  local name="$1" destination="$2" entry encoded index
  local -a manifest_includes=() manifest_excludes=()

  [[ "$REPOSITORY_STATE_SOURCE" == "$destination" ]] \
    || die "Repository '$name' artifact source does not match its manifest destination."
  for entry in "${RESTORE_REPOSITORY_INCLUDES[@]}"; do
    [[ "${entry%%|*}" == "$name" ]] || continue
    manifest_includes+=("${entry#*|}")
  done
  for entry in "${RESTORE_REPOSITORY_EXCLUDES[@]}"; do
    [[ "${entry%%|*}" == "$name" ]] || continue
    manifest_excludes+=("${entry#*|}")
  done
  [[ ${#manifest_includes[@]} -eq ${#REPOSITORY_STATE_INCLUDES[@]} \
    && ${#manifest_excludes[@]} -eq ${#REPOSITORY_STATE_EXCLUDES[@]} ]] \
    || die "Repository '$name' artifact selection rules do not match its manifest."
  for ((index=0; index<${#manifest_includes[@]}; index++)); do
    [[ "${manifest_includes[$index]}" == "${REPOSITORY_STATE_INCLUDES[$index]}" ]] \
      || die "Repository '$name' include rules do not match its artifact."
  done
  for ((index=0; index<${#manifest_excludes[@]}; index++)); do
    [[ "${manifest_excludes[$index]}" == "${REPOSITORY_STATE_EXCLUDES[$index]}" ]] \
      || die "Repository '$name' exclude rules do not match its artifact."
  done
  return 0
}

restore_repositories_domain() {
  local entry name encoded destination parent download_root artifact staging_root staged scratch index
  local -a staged_names=() staged_destinations=() staged_paths=()

  for entry in "${RESTORE_REPOSITORIES[@]}"; do
    name="${entry%%|*}"
    repository_is_requested "$name" || continue
    encoded="${entry#*|}"
    destination="$(decode_field "$encoded")" \
      || die "Repository '$name' has an invalid encoded restore path."
    repository_require_safe_destination_parent "$destination"
    should_overwrite_path "$destination" || continue

    parent="$(dirname -- "$destination")"
    if [[ "$DRY_RUN" == true ]]; then
      download_root="$(mktemp -d "${TMPDIR:-/tmp}/mint-jelly-repository-dry-run.XXXXXX")"
    else
      [[ ! -L "$MINT_JELLY_STATE_DIR" \
        && ( ! -e "$MINT_JELLY_STATE_DIR" || -d "$MINT_JELLY_STATE_DIR" ) ]] \
        || die "Unsafe Mint Jelly state directory: $MINT_JELLY_STATE_DIR"
      mkdir -p -- "$MINT_JELLY_STATE_DIR" "$parent"
      chmod 0700 -- "$MINT_JELLY_STATE_DIR"
      repository_require_safe_destination_parent "$destination"
      download_root="$(mktemp -d "$MINT_JELLY_STATE_DIR/.repository-download.XXXXXX")"
    fi
    TEMP_DIRS+=("$download_root")
    artifact="$download_root/artifact"
    scratch="$download_root/verify"
    mkdir -- "$artifact" "$scratch"
    snapshot_download_domain_entry repositories "$name" "$artifact"
    repository_verify_artifact "$artifact" "$name" "$scratch"
    repository_artifact_matches_manifest "$name" "$destination"

    if [[ "$DRY_RUN" == true ]]; then
      log "Would restore repository '$name': $destination"
      rm -rf -- "$download_root"
      continue
    fi

    staging_root="$(mktemp -d "$parent/.mint-jelly-restore.XXXXXX")"
    TEMP_DIRS+=("$staging_root")
    staged="$staging_root/worktree"
    repository_restore_artifact "$artifact" "$staged" "$name" "$scratch" true
    staged_names+=("$name")
    staged_destinations+=("$destination")
    staged_paths+=("$staged")
    rm -rf -- "$download_root"
  done

  for ((index=0; index<${#staged_names[@]}; index++)); do
    name="${staged_names[$index]}"
    destination="${staged_destinations[$index]}"
    staged="${staged_paths[$index]}"
    repository_require_safe_destination_parent "$destination"
    log "Restoring repository '$name': $destination"
    replace_repository_destination "$staged" "$destination"
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
    --repository) [[ $# -ge 2 ]] || die '--repository requires a name.'; REQUESTED_REPOSITORIES+=("$2"); shift 2 ;;
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
domain_exists "$RESTORE_DOMAIN" || die "Unknown restore domain: $RESTORE_DOMAIN"
(( ${#REQUESTED_REPOSITORIES[@]} == 0 )) || [[ "$RESTORE_DOMAIN" == 'repositories' ]] \
  || die '--repository is valid only with --domain repositories.'
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
snapshot_assert_format
load_snapshot_metadata
load_selected_domains
[[ "$RECORDED_HOSTNAME" == "$SOURCE_HOST" ]] \
  || die "Snapshot hostname '$RECORDED_HOSTNAME' does not match requested source host '$SOURCE_HOST'."
print_plan
[[ "$LIST_ONLY" == 'false' ]] || exit 0
prepare_restored_configuration
validate_platform
confirm_restore
if domain_is_selected "$RESTORE_DOMAIN" software; then restore_software_plan; fi
if domain_is_selected "$RESTORE_DOMAIN" files; then
  restore_path_array files "${RESTORE_FILE_PATHS[@]}"
fi
if domain_is_selected "$RESTORE_DOMAIN" software; then
  restore_path_array software "${RESTORE_APPLICATION_PATHS[@]}"
fi
if domain_is_selected "$RESTORE_DOMAIN" repositories; then
  restore_repositories_domain
fi
if domain_is_selected "$RESTORE_DOMAIN" system-settings; then
  restore_path_array system-settings "${RESTORE_SETTING_ASSETS[@]}"
  apply_system_settings
fi
[[ "$DRY_RUN" == true ]] || config_write
remote_lock_release || die 'Could not release the remote operation lock.'
remote_close
local_operation_lock_release
trap - EXIT
[[ "$DRY_RUN" == 'true' ]] && log 'Restore dry run completed; no local data was changed.' \
  || log "Restore from snapshot $SNAPSHOT_ID completed successfully."
