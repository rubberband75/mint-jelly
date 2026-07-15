#!/usr/bin/env bash

CONFIG_VERSION='3'
DEFAULT_REMOTE=''
HISTORY_KEEP='5'
FILE_SPECS=()
REPOSITORY_NAMES=()
APPLICATIONS=()
SYSTEM_SETTINGS=()
APT_PACKAGES=()
INSTALLERS=()
INSTALLER_OPTION_SELECTIONS=()
FLATPAK_APPS=()
REMOTE_NAMES=()
declare -Ag REPOSITORY_PATH=()
declare -Ag REPOSITORY_INCLUDES=()
declare -Ag REPOSITORY_EXCLUDES=()
declare -Ag REMOTE_TYPE=()
declare -Ag REMOTE_HOST=()
declare -Ag REMOTE_USERNAME=()
declare -Ag REMOTE_PORT=()
declare -Ag REMOTE_ROOT_PATH=()

# Repository include/exclude values cannot contain control characters, so an
# ASCII record separator is an unambiguous in-memory array encoding on every
# Bash version supported by Linux Mint.
REPOSITORY_VALUE_SEPARATOR=$'\036'

config_reset() {
  CONFIG_VERSION='3'
  DEFAULT_REMOTE=''
  HISTORY_KEEP='5'
  FILE_SPECS=()
  REPOSITORY_NAMES=()
  APPLICATIONS=()
  SYSTEM_SETTINGS=()
  APT_PACKAGES=()
  INSTALLERS=()
  INSTALLER_OPTION_SELECTIONS=()
  FLATPAK_APPS=()
  REMOTE_NAMES=()
  REPOSITORY_PATH=()
  REPOSITORY_INCLUDES=()
  REPOSITORY_EXCLUDES=()
  REMOTE_TYPE=()
  REMOTE_HOST=()
  REMOTE_USERNAME=()
  REMOTE_PORT=()
  REMOTE_ROOT_PATH=()
}

config_initialize_defaults() {
  local defaults_file="${MINT_JELLY_DEFAULT_CONFIG_FILE:-$SCRIPT_DIR/backup.conf.default}"

  config_read "$defaults_file" \
    || die "Default backup configuration does not exist: $defaults_file"
}

config_initialize_if_missing() {
  if [[ ! -f "$MINT_JELLY_CONFIG_FILE" ]]; then
    config_initialize_defaults
    config_write
  fi
}

validate_flatpak_app_spec() {
  local spec="$1"
  local remote branch

  [[ "$spec" =~ ^(user|system)\|([A-Za-z0-9][A-Za-z0-9._-]*)\|([A-Za-z0-9][A-Za-z0-9._-]+)\|([A-Za-z0-9][A-Za-z0-9._-]*)$ ]] \
    || return 1
  remote="${BASH_REMATCH[2]}"
  branch="${BASH_REMATCH[4]}"
  validate_safe_name "$remote" && validate_safe_name "$branch"
}

resolve_file_spec() {
  local spec="$1"

  if [[ "$spec" == '~/'* ]]; then
    printf '%s/%s\n' "$HOME" "${spec:2}"
  else
    printf '%s\n' "$spec"
  fi
}

validate_file_spec() {
  local resolved

  resolved="$(resolve_file_spec "$1")"
  validate_absolute_path "$resolved"
}

resolve_repository_path() {
  resolve_file_spec "$1"
}

validate_repository_path() {
  local resolved

  resolved="$(resolve_repository_path "$1")"
  validate_absolute_path "$resolved"
}

validate_repository_relative_path() {
  local path="$1" component
  local -a components=()

  [[ -n "$path" && "$path" != /* && "$path" != */ && "$path" != *//* ]] \
    || return 1
  [[ ! "$path" =~ [[:cntrl:]] ]] || return 1
  IFS='/' read -r -a components <<< "$path"
  for component in "${components[@]}"; do
    [[ -n "$component" && "$component" != '.' && "$component" != '..' \
      && "$component" != '.git' ]] || return 1
  done
}

repository_exists() {
  [[ -n "${REPOSITORY_PATH[$1]+set}" ]]
}

config_add_repository_name() {
  local name="$1"

  if ! repository_exists "$name"; then
    REPOSITORY_NAMES+=("$name")
    REPOSITORY_PATH["$name"]=''
    REPOSITORY_INCLUDES["$name"]=''
    REPOSITORY_EXCLUDES["$name"]=''
  fi
}

config_repository_get_values() {
  local map_name="$1" name="$2" output_name="$3" encoded value
  local -n map_ref="$map_name"
  local -n output_ref="$output_name"

  output_ref=()
  encoded="${map_ref[$name]-}"
  while [[ -n "$encoded" ]]; do
    if [[ "$encoded" == *"$REPOSITORY_VALUE_SEPARATOR"* ]]; then
      value="${encoded%%"$REPOSITORY_VALUE_SEPARATOR"*}"
      encoded="${encoded#*"$REPOSITORY_VALUE_SEPARATOR"}"
    else
      value="$encoded"
      encoded=''
    fi
    output_ref+=("$value")
  done
}

config_repository_get_includes() {
  config_repository_get_values REPOSITORY_INCLUDES "$1" "$2"
}

config_repository_get_excludes() {
  config_repository_get_values REPOSITORY_EXCLUDES "$1" "$2"
}

config_repository_value_exists() {
  local map_name="$1" name="$2" wanted="$3" value
  local -a values=()

  config_repository_get_values "$map_name" "$name" values
  for value in "${values[@]}"; do
    [[ "$value" == "$wanted" ]] && return 0
  done
  return 1
}

config_repository_append_value() {
  local map_name="$1" name="$2" value="$3"
  local -n map_ref="$map_name"

  if [[ -n "${map_ref[$name]-}" ]]; then
    map_ref["$name"]+="$REPOSITORY_VALUE_SEPARATOR$value"
  else
    map_ref["$name"]="$value"
  fi
}

config_repository_add_include() {
  config_repository_append_value REPOSITORY_INCLUDES "$1" "$2"
}

config_repository_add_exclude() {
  config_repository_append_value REPOSITORY_EXCLUDES "$1" "$2"
}

config_repository_remove_value() {
  local map_name="$1" name="$2" removed="$3" value found='false'
  local -n map_ref="$map_name"
  local -a values=()

  config_repository_get_values "$map_name" "$name" values
  map_ref["$name"]=''
  for value in "${values[@]}"; do
    if [[ "$value" == "$removed" ]]; then
      found='true'
    else
      config_repository_append_value "$map_name" "$name" "$value"
    fi
  done
  [[ "$found" == 'true' ]]
}

config_repository_remove_include() {
  config_repository_remove_value REPOSITORY_INCLUDES "$1" "$2"
}

config_repository_remove_exclude() {
  config_repository_remove_value REPOSITORY_EXCLUDES "$1" "$2"
}

config_remove_repository() {
  local removed="$1" name
  local -a retained=()

  for name in "${REPOSITORY_NAMES[@]}"; do
    [[ "$name" == "$removed" ]] || retained+=("$name")
  done
  REPOSITORY_NAMES=("${retained[@]}")
  unset 'REPOSITORY_PATH[$removed]'
  unset 'REPOSITORY_INCLUDES[$removed]'
  unset 'REPOSITORY_EXCLUDES[$removed]'
}

config_paths_overlap() {
  local first="$1" second="$2"

  while [[ "$first" == *//* ]]; do first="${first//\/\//\/}"; done
  while [[ "$second" == *//* ]]; do second="${second//\/\//\/}"; done
  first="${first%/}"
  second="${second%/}"
  [[ "$first" == "$second" || "$first" == "$second/"* || "$second" == "$first/"* ]]
}

config_repository_rules_overlap() {
  config_paths_overlap "/$1" "/$2"
}

remote_exists() {
  [[ -n "${REMOTE_TYPE[$1]+set}" ]]
}

config_add_remote_name() {
  local name="$1"

  if ! remote_exists "$name"; then
    REMOTE_NAMES+=("$name")
    REMOTE_TYPE["$name"]=''
    REMOTE_HOST["$name"]=''
    REMOTE_USERNAME["$name"]=''
    REMOTE_PORT["$name"]='22'
    REMOTE_ROOT_PATH["$name"]=''
  fi
}

config_validate_remote() {
  local name="$1"
  local type="${REMOTE_TYPE[$name]-}"
  local root_path="${REMOTE_ROOT_PATH[$name]-}"

  validate_safe_name "$name" || die "Invalid remote name: $name"
  [[ "$type" == 'ssh' || "$type" == 'local' ]] \
    || die "Remote '$name' has invalid type '$type'; expected ssh or local."
  validate_absolute_path "$root_path" \
    || die "Remote '$name' must have a safe absolute root_path other than /."

  if [[ "$type" == 'ssh' ]]; then
    [[ "${REMOTE_HOST[$name]-}" =~ ^[A-Za-z0-9._:-]+$ ]] \
      || die "Remote '$name' has an invalid SSH hostname."
    [[ "${REMOTE_USERNAME[$name]-}" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]] \
      || die "Remote '$name' has an invalid SSH username."
    [[ "${REMOTE_PORT[$name]-}" =~ ^[0-9]+$ ]] \
      && (( 10#${REMOTE_PORT[$name]} >= 1 && 10#${REMOTE_PORT[$name]} <= 65535 )) \
      || die "Remote '$name' has an invalid SSH port."
  fi
}

config_validate() {
  local source application setting package installer selection option owner name flatpak_app
  local repository_name repository_path other_repository include exclude protected
  local flatpak_scope flatpak_remote flatpak_id flatpak_branch flatpak_target
  local -A seen_sources=() seen_applications=() seen_settings=() seen_packages=() seen_installers=()
  local -A seen_installer_options=()
  local -A seen_flatpak_apps=()
  local -A seen_flatpak_targets=()
  local -A seen_repositories=() resolved_repository_paths=()
  local -A seen_includes=() seen_excludes=()
  local -a repository_includes=() repository_excludes=()

  [[ "$CONFIG_VERSION" == '3' ]] \
    || die "Unsupported configuration version: $CONFIG_VERSION"
  [[ "$HISTORY_KEEP" =~ ^(0|[1-9][0-9]*)$ ]] \
    || die 'history_keep must be a non-negative integer without leading zeroes.'
  for source in "${FILE_SPECS[@]}"; do
    validate_file_spec "$source" \
      || die "File path must be ~/... or a safe absolute path other than /: $source"
    [[ -z "${seen_sources[$source]+set}" ]] \
      || die "Backup source is listed more than once: $source"
    seen_sources["$source"]=1
  done

  for repository_name in "${REPOSITORY_NAMES[@]}"; do
    validate_safe_name "$repository_name" \
      || die "Invalid repository name: $repository_name"
    [[ -z "${seen_repositories[$repository_name]+set}" ]] \
      || die "Repository is configured more than once: $repository_name"
    seen_repositories["$repository_name"]=1

    repository_path="${REPOSITORY_PATH[$repository_name]-}"
    [[ -n "$repository_path" ]] \
      || die "Repository '$repository_name' must define exactly one path."
    validate_repository_path "$repository_path" \
      || die "Repository '$repository_name' path must be ~/... or a safe absolute path other than /: $repository_path"
    repository_path="$(resolve_repository_path "$repository_path")"

    for protected in "$MINT_JELLY_CONFIG_DIR" "$MINT_JELLY_STATE_DIR" "$MINT_JELLY_CACHE_DIR"; do
      if config_paths_overlap "$repository_path" "$protected"; then
        die "Repository '$repository_name' overlaps Mint Jelly internal data: $protected"
      fi
    done

    for source in "${FILE_SPECS[@]}"; do
      if config_paths_overlap "$repository_path" "$(resolve_file_spec "$source")"; then
        die "Repository '$repository_name' overlaps configured file path: $source"
      fi
    done
    for other_repository in "${!resolved_repository_paths[@]}"; do
      if config_paths_overlap "$repository_path" "${resolved_repository_paths[$other_repository]}"; then
        die "Repository '$repository_name' overlaps repository '$other_repository'."
      fi
    done
    resolved_repository_paths["$repository_name"]="$repository_path"

    config_repository_get_includes "$repository_name" repository_includes
    config_repository_get_excludes "$repository_name" repository_excludes
    seen_includes=()
    seen_excludes=()
    for include in "${repository_includes[@]}"; do
      validate_repository_relative_path "$include" \
        || die "Repository '$repository_name' has an unsafe include path: $include"
      [[ -z "${seen_includes[$include]+set}" ]] \
        || die "Repository '$repository_name' include is listed more than once: $include"
      seen_includes["$include"]=1
    done
    for exclude in "${repository_excludes[@]}"; do
      validate_repository_relative_path "$exclude" \
        || die "Repository '$repository_name' has an unsafe exclude path: $exclude"
      [[ -z "${seen_excludes[$exclude]+set}" ]] \
        || die "Repository '$repository_name' exclude is listed more than once: $exclude"
      seen_excludes["$exclude"]=1
      for include in "${repository_includes[@]}"; do
        config_repository_rules_overlap "$include" "$exclude" \
          && die "Repository '$repository_name' has conflicting include/exclude paths: $include and $exclude"
      done
    done
  done

  for application in "${APPLICATIONS[@]}"; do
    validate_safe_name "$application" || die "Invalid application profile name: $application"
    [[ -z "${seen_applications[$application]+set}" ]] \
      || die "Application profile is listed more than once: $application"
    seen_applications["$application"]=1
  done

  for setting in "${SYSTEM_SETTINGS[@]}"; do
    validate_safe_name "$setting" || die "Invalid system-settings profile name: $setting"
    [[ -z "${seen_settings[$setting]+set}" ]] \
      || die "System-settings profile is listed more than once: $setting"
    seen_settings["$setting"]=1
  done

  for package in "${APT_PACKAGES[@]}"; do
    validate_apt_package_name "$package" \
      || die "Invalid APT package name: $package"
    [[ -z "${seen_packages[$package]+set}" ]] \
      || die "APT package is listed more than once: $package"
    seen_packages["$package"]=1
  done

  for installer in "${INSTALLERS[@]}"; do
    validate_safe_name "$installer" || die "Invalid installer name: $installer"
    [[ -z "${seen_installers[$installer]+set}" ]] \
      || die "Installer is listed more than once: $installer"
    seen_installers["$installer"]=1
  done

  for selection in "${INSTALLER_OPTION_SELECTIONS[@]}"; do
    [[ "$selection" =~ ^([A-Za-z0-9][A-Za-z0-9._-]*):([A-Za-z0-9][A-Za-z0-9._-]*)$ ]] \
      || die "Invalid installer option selection: $selection"
    owner="${BASH_REMATCH[1]}"
    option="${BASH_REMATCH[2]}"
    validate_safe_name "$owner" && validate_safe_name "$option" \
      || die "Invalid installer option selection: $selection"
    [[ -n "${seen_installers[$owner]+set}" ]] \
      || die "Installer option '$selection' belongs to an installer that is not selected."
    [[ -z "${seen_installer_options[$selection]+set}" ]] \
      || die "Installer option is listed more than once: $selection"
    seen_installer_options["$selection"]=1
  done

  for flatpak_app in "${FLATPAK_APPS[@]}"; do
    validate_flatpak_app_spec "$flatpak_app" \
      || die "Invalid Flatpak application selection: $flatpak_app"
    [[ -z "${seen_flatpak_apps[$flatpak_app]+set}" ]] \
      || die "Flatpak application is listed more than once: $flatpak_app"
    seen_flatpak_apps["$flatpak_app"]=1
    IFS='|' read -r flatpak_scope flatpak_remote flatpak_id flatpak_branch <<< "$flatpak_app"
    flatpak_target="$flatpak_scope|$flatpak_id"
    [[ -z "${seen_flatpak_targets[$flatpak_target]+set}" ]] \
      || die "Flatpak application has more than one configured origin or branch: $flatpak_target"
    seen_flatpak_targets["$flatpak_target"]=1
  done

  for name in "${REMOTE_NAMES[@]}"; do
    config_validate_remote "$name"
    if [[ "${REMOTE_TYPE[$name]}" == local ]]; then
      for repository_name in "${!resolved_repository_paths[@]}"; do
        if config_paths_overlap "${resolved_repository_paths[$repository_name]}" "${REMOTE_ROOT_PATH[$name]}"; then
          die "Repository '$repository_name' overlaps local backup remote '$name'."
        fi
      done
    fi
  done

  if [[ -n "$DEFAULT_REMOTE" ]]; then
    remote_exists "$DEFAULT_REMOTE" \
      || die "Default remote does not exist: $DEFAULT_REMOTE"
  fi
}

config_read() {
  local file="${1:-$MINT_JELLY_CONFIG_FILE}"
  local raw line key value section='' remote_name='' repository_name='' line_number=0
  local -A seen_global_keys=() seen_remote_keys=() seen_repository_keys=()

  [[ -f "$file" ]] || return 1
  config_reset

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    ((line_number += 1))
    line="$(trim "$raw")"
    [[ -z "$line" || "$line" == \#* || "$line" == \;* ]] && continue

    if [[ "$line" =~ ^\[remote[[:space:]]+([A-Za-z0-9._-]+)\]$ ]]; then
      remote_name="${BASH_REMATCH[1]}"
      validate_safe_name "$remote_name" \
        || die "$file:$line_number: invalid remote name."
      remote_exists "$remote_name" \
        && die "$file:$line_number: duplicate remote '$remote_name'."
      config_add_remote_name "$remote_name"
      section='remote'
      repository_name=''
      continue
    fi

    if [[ "$line" =~ ^\[repository[[:space:]]+([A-Za-z0-9._-]+)\]$ ]]; then
      repository_name="${BASH_REMATCH[1]}"
      validate_safe_name "$repository_name" \
        || die "$file:$line_number: invalid repository name."
      repository_exists "$repository_name" \
        && die "$file:$line_number: duplicate repository '$repository_name'."
      config_add_repository_name "$repository_name"
      section='repository'
      remote_name=''
      continue
    fi

    [[ "$line" != \[* ]] || die "$file:$line_number: unknown or malformed section."

    [[ "$line" == *=* ]] || die "$file:$line_number: expected key=value."
    key="$(trim "${line%%=*}")"
    value="$(trim "${line#*=}")"
    [[ -n "$value" ]] || die "$file:$line_number: '$key' cannot be empty."

    if [[ "$section" == 'remote' ]]; then
      [[ -z "${seen_remote_keys["$remote_name:$key"]+set}" ]] \
        || die "$file:$line_number: duplicate key '$key' in remote '$remote_name'."
      seen_remote_keys["$remote_name:$key"]=1
      case "$key" in
        type) REMOTE_TYPE["$remote_name"]="$value" ;;
        host) REMOTE_HOST["$remote_name"]="$value" ;;
        username) REMOTE_USERNAME["$remote_name"]="$value" ;;
        port) REMOTE_PORT["$remote_name"]="$value" ;;
        root_path) REMOTE_ROOT_PATH["$remote_name"]="$value" ;;
        *) die "$file:$line_number: unknown remote key '$key'." ;;
      esac
    elif [[ "$section" == 'repository' ]]; then
      case "$key" in
        path)
          [[ -z "${seen_repository_keys["$repository_name:path"]+set}" ]] \
            || die "$file:$line_number: duplicate path in repository '$repository_name'."
          seen_repository_keys["$repository_name:path"]=1
          REPOSITORY_PATH["$repository_name"]="$value"
          ;;
        include) config_repository_add_include "$repository_name" "$value" ;;
        exclude) config_repository_add_exclude "$repository_name" "$value" ;;
        *) die "$file:$line_number: unknown key '$key' in repository '$repository_name'." ;;
      esac
    else
      case "$key" in
        version|default_remote|history_keep)
          [[ -z "${seen_global_keys[$key]+set}" ]] \
            || die "$file:$line_number: duplicate global key '$key'."
          seen_global_keys["$key"]=1
          case "$key" in
            version) CONFIG_VERSION="$value" ;;
            default_remote) DEFAULT_REMOTE="$value" ;;
            history_keep) HISTORY_KEEP="$value" ;;
          esac
          ;;
        file) FILE_SPECS+=("$value") ;;
        application) APPLICATIONS+=("$value") ;;
        system_setting) SYSTEM_SETTINGS+=("$value") ;;
        apt_package) APT_PACKAGES+=("$value") ;;
        installer) INSTALLERS+=("$value") ;;
        installer_option) INSTALLER_OPTION_SELECTIONS+=("$value") ;;
        flatpak_app) FLATPAK_APPS+=("$value") ;;
        *) die "$file:$line_number: unknown global key '$key'." ;;
      esac
    fi
  done < "$file"

  config_validate
}

config_write() {
  local file="${1:-$MINT_JELLY_CONFIG_FILE}"
  local temp_file source application setting package installer selection flatpak_app name value
  local -a repository_values=()

  config_validate
  ensure_config_dir
  temp_file="$(mktemp "${MINT_JELLY_CONFIG_DIR}/.config.ini.XXXXXX")"
  chmod 0600 -- "$temp_file"

  {
    printf '# Mint Jelly configuration\n'
    printf 'version=%s\n' "$CONFIG_VERSION"
    [[ -n "$DEFAULT_REMOTE" ]] && printf 'default_remote=%s\n' "$DEFAULT_REMOTE"
    printf 'history_keep=%s\n' "$HISTORY_KEEP"
    for source in "${FILE_SPECS[@]}"; do
      printf 'file=%s\n' "$source"
    done
    for application in "${APPLICATIONS[@]}"; do
      printf 'application=%s\n' "$application"
    done
    for setting in "${SYSTEM_SETTINGS[@]}"; do
      printf 'system_setting=%s\n' "$setting"
    done
    for package in "${APT_PACKAGES[@]}"; do
      printf 'apt_package=%s\n' "$package"
    done
    for installer in "${INSTALLERS[@]}"; do
      printf 'installer=%s\n' "$installer"
    done
    for selection in "${INSTALLER_OPTION_SELECTIONS[@]}"; do
      printf 'installer_option=%s\n' "$selection"
    done
    for flatpak_app in "${FLATPAK_APPS[@]}"; do
      printf 'flatpak_app=%s\n' "$flatpak_app"
    done

    for name in "${REPOSITORY_NAMES[@]}"; do
      printf '\n[repository %s]\n' "$name"
      printf 'path=%s\n' "${REPOSITORY_PATH[$name]}"
      config_repository_get_includes "$name" repository_values
      for value in "${repository_values[@]}"; do
        printf 'include=%s\n' "$value"
      done
      config_repository_get_excludes "$name" repository_values
      for value in "${repository_values[@]}"; do
        printf 'exclude=%s\n' "$value"
      done
    done

    for name in "${REMOTE_NAMES[@]}"; do
      printf '\n[remote %s]\n' "$name"
      printf 'type=%s\n' "${REMOTE_TYPE[$name]}"
      if [[ "${REMOTE_TYPE[$name]}" == 'ssh' ]]; then
        printf 'host=%s\n' "${REMOTE_HOST[$name]}"
        printf 'username=%s\n' "${REMOTE_USERNAME[$name]}"
        printf 'port=%s\n' "${REMOTE_PORT[$name]}"
      fi
      printf 'root_path=%s\n' "${REMOTE_ROOT_PATH[$name]}"
    done
  } > "$temp_file"

  mv -f -- "$temp_file" "$file"
  chmod 0600 -- "$file"
}
