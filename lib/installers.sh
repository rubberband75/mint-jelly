#!/usr/bin/env bash

# Loader for trusted installer modules bundled with the active Mint Jelly
# release. Remote recovery data may select an ID, but never supplies code.

INSTALLER_NAMES=()
declare -Ag INSTALLER_DISPLAY_NAME=()
declare -Ag INSTALLER_DESCRIPTION=()
declare -Ag INSTALLER_NETWORK=()
declare -Ag INSTALLER_PRIVILEGE=()
declare -Ag INSTALLER_INTERACTIVE=()
declare -Ag INSTALLER_ARCHITECTURES=()
declare -Ag INSTALLER_VERIFICATION=()
declare -Ag INSTALLER_RUN_SCRIPT=()
declare -Ag INSTALLER_OPTION_IDS=()

installer_reset_registry() {
  INSTALLER_NAMES=()
  INSTALLER_DISPLAY_NAME=()
  INSTALLER_DESCRIPTION=()
  INSTALLER_NETWORK=()
  INSTALLER_PRIVILEGE=()
  INSTALLER_INTERACTIVE=()
  INSTALLER_ARCHITECTURES=()
  INSTALLER_VERIFICATION=()
  INSTALLER_RUN_SCRIPT=()
  INSTALLER_OPTION_IDS=()
}

installer_metadata_text_is_safe() {
  [[ -n "$1" && ! "$1" =~ [[:cntrl:]] ]]
}

installer_path_permissions_are_safe() {
  local mode permissions

  mode="$(stat -c '%a' -- "$1" 2>/dev/null)" || return 1
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  permissions=$((8#$mode))
  (( (permissions & 8#022) == 0 ))
}

load_installer_directory() {
  local directory="$1"
  local expected_id="${directory##*/}"
  local metadata_file="$directory/installer.conf"
  local run_script="$directory/run.sh"
  local raw key value line_number=0
  local id='' name='' description='' network='' privilege=''
  local interactive='' architectures='' verification=''
  local option
  local -a options=()
  local -A seen=() seen_options=()

  [[ -d "$directory" && ! -L "$directory" ]] \
    || die "Installer path is not a safe directory: $directory"
  [[ -f "$metadata_file" && ! -L "$metadata_file" ]] \
    || die "Installer '$expected_id' is missing installer.conf."
  [[ -f "$run_script" && ! -L "$run_script" && -x "$run_script" ]] \
    || die "Installer '$expected_id' is missing an executable run.sh."
  installer_path_permissions_are_safe "$directory" \
    || die "Installer directory '$expected_id' must not be group- or world-writable."
  installer_path_permissions_are_safe "$metadata_file" \
    || die "Installer '$expected_id' metadata must not be group- or world-writable."
  installer_path_permissions_are_safe "$run_script" \
    || die "Installer '$expected_id' run script must not be group- or world-writable."

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    ((line_number += 1))
    [[ "$raw" != *$'\r'* ]] \
      || die "$metadata_file:$line_number: carriage returns are not allowed."
    raw="$(trim "$raw")"
    [[ -z "$raw" || "$raw" == \#* ]] && continue
    [[ "$raw" == *=* ]] \
      || die "$metadata_file:$line_number: expected key=value."
    key="$(trim "${raw%%=*}")"
    value="$(trim "${raw#*=}")"
    [[ -n "$value" ]] || die "$metadata_file:$line_number: '$key' cannot be empty."
    if [[ "$key" != 'option' ]]; then
      [[ -z "${seen[$key]+set}" ]] \
        || die "$metadata_file:$line_number: duplicate key '$key'."
      seen["$key"]=1
    fi
    case "$key" in
      id) id="$value" ;;
      name) name="$value" ;;
      description) description="$value" ;;
      network) network="$value" ;;
      privilege) privilege="$value" ;;
      interactive) interactive="$value" ;;
      architectures) architectures="$value" ;;
      verification) verification="$value" ;;
      option)
        validate_safe_name "$value" \
          || die "$metadata_file:$line_number: invalid installer option '$value'."
        [[ -z "${seen_options[$value]+set}" ]] \
          || die "$metadata_file:$line_number: duplicate installer option '$value'."
        seen_options["$value"]=1
        options+=("$value")
        ;;
      *) die "$metadata_file:$line_number: unknown key '$key'." ;;
    esac
  done < "$metadata_file"

  [[ "$id" == "$expected_id" ]] \
    || die "Installer directory '$expected_id' declares mismatched id '$id'."
  validate_safe_name "$id" || die "Installer declares an invalid id: $id"
  [[ -z "${INSTALLER_RUN_SCRIPT[$id]+set}" ]] \
    || die "Installer registered more than once: $id"
  installer_metadata_text_is_safe "$name" \
    || die "Installer '$id' has an invalid display name."
  installer_metadata_text_is_safe "$description" \
    || die "Installer '$id' has an invalid description."
  [[ "$network" == 'required' || "$network" == 'none' ]] \
    || die "Installer '$id' has invalid network metadata: $network"
  [[ "$privilege" == 'system' || "$privilege" == 'user' ]] \
    || die "Installer '$id' has invalid privilege metadata: $privilege"
  [[ "$interactive" == 'yes' || "$interactive" == 'no' ]] \
    || die "Installer '$id' has invalid interactive metadata: $interactive"
  [[ "$architectures" =~ ^[a-z0-9][a-z0-9-]*(\ [a-z0-9][a-z0-9-]*)*$ ]] \
    || die "Installer '$id' has invalid architecture metadata: $architectures"
  [[ "$verification" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
    || die "Installer '$id' has invalid verification metadata: $verification"

  INSTALLER_NAMES+=("$id")
  INSTALLER_DISPLAY_NAME["$id"]="$name"
  INSTALLER_DESCRIPTION["$id"]="$description"
  INSTALLER_NETWORK["$id"]="$network"
  INSTALLER_PRIVILEGE["$id"]="$privilege"
  INSTALLER_INTERACTIVE["$id"]="$interactive"
  INSTALLER_ARCHITECTURES["$id"]="$architectures"
  INSTALLER_VERIFICATION["$id"]="$verification"
  INSTALLER_RUN_SCRIPT["$id"]="$run_script"
  INSTALLER_OPTION_IDS["$id"]="${options[*]}"
}

load_installers() {
  local directory installers_root
  local -a directories=()

  installer_reset_registry
  installers_root="${MINT_JELLY_INSTALLERS_DIR:-$SCRIPT_DIR/installers}"
  shopt -s nullglob
  directories=("$installers_root/"*)
  shopt -u nullglob
  for directory in "${directories[@]}"; do
    [[ -d "$directory" ]] || continue
    load_installer_directory "$directory"
  done
}

installer_exists() {
  [[ -n "${INSTALLER_RUN_SCRIPT[$1]-}" ]]
}

require_configured_installers_available() {
  local installer

  for installer in "${INSTALLERS[@]}"; do
    installer_exists "$installer" \
      || die "Unknown installer '$installer'. Available installers: ${INSTALLER_NAMES[*]:-none}"
  done
}

installer_option_exists() {
  local installer="$1"
  local expected="$2"
  local option

  for option in ${INSTALLER_OPTION_IDS[$installer]-}; do
    [[ "$option" == "$expected" ]] && return 0
  done
  return 1
}

require_configured_installer_options_available() {
  local selection installer option

  for selection in "${INSTALLER_OPTION_SELECTIONS[@]}"; do
    installer="${selection%%:*}"
    option="${selection#*:}"
    installer_exists "$installer" \
      || die "Installer option '$selection' belongs to an unavailable installer."
    installer_option_exists "$installer" "$option" \
      || die "Unknown option '$option' for installer '$installer'."
  done
}

installer_supports_architecture() {
  local installer="$1"
  local architecture="$2"
  local supported

  for supported in ${INSTALLER_ARCHITECTURES[$installer]}; do
    [[ "$supported" == "$architecture" || "$supported" == 'all' ]] && return 0
  done
  return 1
}
