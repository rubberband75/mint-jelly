#!/usr/bin/env bash

CONFIG_VERSION='1'
DEFAULT_REMOTE=''
HISTORY_KEEP='5'
BACKUP_SOURCE_SPECS=()
BACKUP_PLUGINS=()
APT_PACKAGES=()
INSTALLERS=()
INSTALLER_OPTION_SELECTIONS=()
REMOTE_NAMES=()
declare -Ag REMOTE_TYPE=()
declare -Ag REMOTE_HOST=()
declare -Ag REMOTE_USERNAME=()
declare -Ag REMOTE_PORT=()
declare -Ag REMOTE_ROOT_PATH=()

config_reset() {
  CONFIG_VERSION='1'
  DEFAULT_REMOTE=''
  HISTORY_KEEP='5'
  BACKUP_SOURCE_SPECS=()
  BACKUP_PLUGINS=()
  APT_PACKAGES=()
  INSTALLERS=()
  INSTALLER_OPTION_SELECTIONS=()
  REMOTE_NAMES=()
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

resolve_backup_source_spec() {
  local spec="$1"

  if [[ "$spec" == '~/'* ]]; then
    printf '%s/%s\n' "$HOME" "${spec:2}"
  else
    printf '%s\n' "$spec"
  fi
}

validate_backup_source_spec() {
  local resolved

  resolved="$(resolve_backup_source_spec "$1")"
  validate_absolute_path "$resolved"
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
  local source plugin package installer selection option owner name
  local -A seen_sources=() seen_plugins=() seen_packages=() seen_installers=()
  local -A seen_installer_options=()

  [[ "$CONFIG_VERSION" == '1' ]] \
    || die "Unsupported configuration version: $CONFIG_VERSION"
  [[ "$HISTORY_KEEP" =~ ^(0|[1-9][0-9]*)$ ]] \
    || die 'history_keep must be a non-negative integer without leading zeroes.'
  (( ${#BACKUP_SOURCE_SPECS[@]} + ${#BACKUP_PLUGINS[@]} > 0 )) \
    || die 'The configuration must contain at least one source or plugin.'

  for source in "${BACKUP_SOURCE_SPECS[@]}"; do
    validate_backup_source_spec "$source" \
      || die "Backup source must be ~/... or a safe absolute path other than /: $source"
    [[ -z "${seen_sources[$source]+set}" ]] \
      || die "Backup source is listed more than once: $source"
    seen_sources["$source"]=1
  done

  for plugin in "${BACKUP_PLUGINS[@]}"; do
    validate_safe_name "$plugin" || die "Invalid backup plugin name: $plugin"
    [[ -z "${seen_plugins[$plugin]+set}" ]] \
      || die "Backup plugin is listed more than once: $plugin"
    seen_plugins["$plugin"]=1
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

  for name in "${REMOTE_NAMES[@]}"; do
    config_validate_remote "$name"
  done

  if [[ -n "$DEFAULT_REMOTE" ]]; then
    remote_exists "$DEFAULT_REMOTE" \
      || die "Default remote does not exist: $DEFAULT_REMOTE"
  fi
}

config_read() {
  local file="${1:-$MINT_JELLY_CONFIG_FILE}"
  local raw line key value section='' remote_name='' line_number=0
  local -A seen_global_keys=() seen_remote_keys=()

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
      continue
    fi

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
        source) BACKUP_SOURCE_SPECS+=("$value") ;;
        backup_plugin) BACKUP_PLUGINS+=("$value") ;;
        apt_package) APT_PACKAGES+=("$value") ;;
        installer) INSTALLERS+=("$value") ;;
        installer_option) INSTALLER_OPTION_SELECTIONS+=("$value") ;;
        *) die "$file:$line_number: unknown global key '$key'." ;;
      esac
    fi
  done < "$file"

  config_validate
}

config_write() {
  local file="${1:-$MINT_JELLY_CONFIG_FILE}"
  local temp_file source plugin package installer selection name

  config_validate
  ensure_config_dir
  temp_file="$(mktemp "${MINT_JELLY_CONFIG_DIR}/.backup.conf.XXXXXX")"
  chmod 0600 -- "$temp_file"

  {
    printf '# Mint Jelly backup configuration\n'
    printf 'version=%s\n' "$CONFIG_VERSION"
    [[ -n "$DEFAULT_REMOTE" ]] && printf 'default_remote=%s\n' "$DEFAULT_REMOTE"
    printf 'history_keep=%s\n' "$HISTORY_KEEP"
    for source in "${BACKUP_SOURCE_SPECS[@]}"; do
      printf 'source=%s\n' "$source"
    done
    for plugin in "${BACKUP_PLUGINS[@]}"; do
      printf 'backup_plugin=%s\n' "$plugin"
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
