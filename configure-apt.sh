#!/usr/bin/env bash
# Manage the curated APT package list saved for future recovery.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/checklist.sh
source "$SCRIPT_DIR/lib/checklist.sh"

APT_CATALOG_FILE="${MINT_JELLY_APT_CATALOG:-$SCRIPT_DIR/catalogs/apt-packages.txt}"
APT_INSTALLED_PACKAGES_LOADED=false
declare -A APT_INSTALLED_VERSION=()

usage() {
  local command_name="${MINT_JELLY_COMMAND:-mint-jelly config apt}"

  cat <<EOF
Usage:
  $command_name list
  $command_name add PACKAGE...
  $command_name remove PACKAGE...
  $command_name select
EOF
}

validate_package_name() {
  validate_apt_package_name "$1"
}

package_is_configured() {
  local expected="$1"
  local package

  for package in "${APT_PACKAGES[@]}"; do
    [[ "$package" == "$expected" ]] && return 0
  done
  return 1
}

load_installed_packages() {
  local package status version base_package

  [[ "$APT_INSTALLED_PACKAGES_LOADED" == 'false' ]] || return 0
  APT_INSTALLED_VERSION=()
  while IFS=$'\t' read -r package status version; do
    [[ "$status" == 'ii ' ]] || continue
    APT_INSTALLED_VERSION["$package"]="$version"
    # Also make the native/unqualified name addressable. Keep the first
    # installed architecture when multiple foreign architectures are present.
    base_package="${package%%:*}"
    if [[ -z "${APT_INSTALLED_VERSION[$base_package]+set}" ]]; then
      APT_INSTALLED_VERSION["$base_package"]="$version"
    fi
  done < <(dpkg-query -W -f='${binary:Package}\t${db:Status-Abbrev}\t${Version}\n' 2>/dev/null || true)
  APT_INSTALLED_PACKAGES_LOADED=true
}

installed_package_version() {
  local package="$1"

  load_installed_packages
  [[ -n "${APT_INSTALLED_VERSION[$package]+set}" ]] || return 1
  printf '%s' "${APT_INSTALLED_VERSION[$package]}"
}

package_is_known() {
  local package="$1"
  local metadata

  if installed_package_version "$package" >/dev/null; then
    return 0
  fi
  metadata="$(apt-cache show "$package" 2>/dev/null || true)"
  [[ "$metadata" == 'Package: '* || "$metadata" == *$'\nPackage: '* ]]
}

list_packages() {
  local package version

  load_installed_packages
  if (( ${#APT_PACKAGES[@]} == 0 )); then
    printf 'No APT packages configured.\n'
    return 0
  fi
  for package in "${APT_PACKAGES[@]}"; do
    if version="$(installed_package_version "$package")"; then
      printf '%-32s installed: %s\n' "$package" "$version"
    else
      printf '%-32s not installed\n' "$package"
    fi
  done
}

add_packages() {
  local package existing array_contains_local
  local -a additions=()

  (( $# > 0 )) || die 'apt add requires at least one package name.'
  require_cmd apt-cache
  require_cmd dpkg-query
  for package in "$@"; do
    validate_package_name "$package" || die "Invalid APT package name: $package"
    package_is_known "$package" \
      || die "APT package is neither installed nor available from configured repositories: $package"
    package_is_configured "$package" && continue
    array_contains_local=false
    for existing in "${additions[@]}"; do
      [[ "$existing" == "$package" ]] && array_contains_local=true
    done
    [[ "$array_contains_local" == 'true' ]] || additions+=("$package")
  done

  if (( ${#additions[@]} == 0 )); then
    log 'All requested APT packages are already configured.'
    return 0
  fi
  APT_PACKAGES+=("${additions[@]}")
  config_write
  log "Added APT packages: ${additions[*]}"
}

remove_packages() {
  local package configured keep
  local -a retained=()

  (( $# > 0 )) || die 'apt remove requires at least one package name.'
  for package in "$@"; do
    validate_package_name "$package" || die "Invalid APT package name: $package"
    package_is_configured "$package" || die "APT package is not configured: $package"
  done

  for configured in "${APT_PACKAGES[@]}"; do
    keep=true
    for package in "$@"; do
      [[ "$configured" == "$package" ]] && keep=false
    done
    [[ "$keep" == 'true' ]] && retained+=("$configured")
  done
  APT_PACKAGES=("${retained[@]}")
  config_write
  log "Removed APT packages: $*"
}

load_catalog_packages() {
  local raw package

  [[ -r "$APT_CATALOG_FILE" ]] || die "APT package catalog is missing: $APT_CATALOG_FILE"
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    package="$(trim "${raw%%#*}")"
    [[ -z "$package" ]] && continue
    validate_package_name "$package" \
      || die "APT package catalog contains an invalid name: $package"
    printf '%s\n' "$package"
  done < "$APT_CATALOG_FILE"
}

confirm_large_package_selection() {
  local original_count="$1"
  local final_count="$2"
  local growth answer expected

  growth=$((final_count - original_count))
  if (( final_count <= 250 \
    && !(growth >= 50 \
      && (original_count == 0 || final_count >= original_count * 2)) )); then
    return 0
  fi

  printf '\nLarge APT recovery selection detected.\n'
  printf '  Previously configured: %d\n' "$original_count"
  printf '  New selection:         %d\n' "$final_count"
  printf 'This may record distribution-provided packages that you did not intend to manage.\n'
  expected="save $final_count"
  printf 'Type "%s" to save this selection, or press Enter to cancel: ' "$expected"
  answer=''
  IFS= read -r answer || true
  [[ "${answer,,}" == "$expected" ]]
}

package_selection_is_unchanged() {
  local package

  (( ${#CHECKLIST_RESULT[@]} == ${#APT_PACKAGES[@]} )) || return 1
  for package in "${CHECKLIST_RESULT[@]}"; do
    package_is_configured "$package" || return 1
  done
}

select_packages() {
  local package version detail status original_count final_count
  local -a candidates=() packages=()

  require_cmd apt-mark
  require_cmd dpkg-query
  load_installed_packages
  mapfile -t candidates < <(
    {
      printf '%s\n' "${APT_PACKAGES[@]}"
      load_catalog_packages
      apt-mark showmanual 2>/dev/null || true
    } | sed '/^$/d' | LC_ALL=C sort -u
  )

  for package in "${candidates[@]}"; do
    validate_package_name "$package" && packages+=("$package")
  done

  CHECKLIST_IDS=("${packages[@]}")
  CHECKLIST_LABELS=("${packages[@]}")
  CHECKLIST_DETAILS=()
  CHECKLIST_INITIAL_SELECTED=()
  for package in "${packages[@]}"; do
    detail=''
    if package_is_configured "$package"; then
      detail='[configured]'
      CHECKLIST_INITIAL_SELECTED+=(1)
    else
      CHECKLIST_INITIAL_SELECTED+=(0)
    fi
    if version="$(installed_package_version "$package")"; then
      [[ -z "$detail" ]] || detail+=' '
      detail+="[installed: $version]"
    fi
    CHECKLIST_DETAILS+=("$detail")
  done
  CHECKLIST_TITLE="Select APT packages for recovery (${#packages[@]} candidates)"
  CHECKLIST_NOTE="Select all affects all ${#packages[@]} candidates. Installed packages remain selectable because this is a recovery list."

  if checklist_run; then
    :
  else
    status=$?
    (( status == 1 )) || exit "$status"
    log 'APT package configuration unchanged.'
    return 0
  fi
  if package_selection_is_unchanged; then
    log 'APT package configuration unchanged.'
    return 0
  fi
  original_count="${#APT_PACKAGES[@]}"
  final_count="${#CHECKLIST_RESULT[@]}"
  if ! confirm_large_package_selection "$original_count" "$final_count"; then
    log 'Large APT package selection was not confirmed; configuration unchanged.'
    return 0
  fi
  APT_PACKAGES=("${CHECKLIST_RESULT[@]}")
  config_write
  if (( ${#APT_PACKAGES[@]} == 0 )); then
    log "APT recovery list cleared in $MINT_JELLY_CONFIG_FILE"
  else
    log "Configured ${#APT_PACKAGES[@]} APT packages."
  fi
}

if [[ $# -eq 1 && ( "$1" == '-h' || "$1" == '--help' ) ]]; then
  usage
  exit 0
fi

require_initialized_config
config_read

case "${1-}" in
  list)
    [[ $# -eq 1 ]] || die 'apt list does not accept arguments.'
    require_cmd dpkg-query
    list_packages
    ;;
  add)
    shift
    add_packages "$@"
    ;;
  remove)
    shift
    remove_packages "$@"
    ;;
  select)
    [[ $# -eq 1 ]] || die 'apt select does not accept arguments.'
    select_packages
    ;;
  -h|--help|'')
    usage
    ;;
  *)
    die "Unknown APT configuration command: $1"
    ;;
esac
