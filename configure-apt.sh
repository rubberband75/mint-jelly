#!/usr/bin/env bash
# Manage the APT package list saved for future recovery.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/checklist.sh
source "$SCRIPT_DIR/lib/checklist.sh"

APT_INITIAL_STATUS_FILE="${MINT_JELLY_APT_INITIAL_STATUS_FILE:-/var/log/installer/initial-status.gz}"
APT_INSTALLED_PACKAGES_LOADED=false
APT_INITIAL_PACKAGES_STATE='unknown'
declare -A APT_INSTALLED_VERSION=()
APT_INSTALLED_PACKAGE_NAMES=()
declare -A APT_INITIAL_PACKAGE=()

usage() {
  local command_name="${MINT_JELLY_COMMAND:-mint-jelly config apt}"

  cat <<EOF
Usage:
  $command_name list
  $command_name add PACKAGE...
  $command_name remove PACKAGE...
  $command_name select [--show-all]

By default, select shows manually marked packages that were not present in
Linux Mint's initial installation snapshot. --show-all includes every
currently installed APT package.
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
  local package status version base_package query_output

  [[ "$APT_INSTALLED_PACKAGES_LOADED" == 'false' ]] || return 0
  APT_INSTALLED_VERSION=()
  APT_INSTALLED_PACKAGE_NAMES=()
  if ! query_output="$(
    dpkg-query -W -f='${binary:Package}\t${db:Status-Abbrev}\t${Version}\n' 2>&1
  )"; then
    die "Could not read installed APT packages: ${query_output:-dpkg-query failed without a diagnostic}"
  fi
  while IFS=$'\t' read -r package status version; do
    [[ "$status" == 'ii ' ]] || continue
    validate_package_name "$package" || continue
    APT_INSTALLED_PACKAGE_NAMES+=("$package")
    APT_INSTALLED_VERSION["$package"]="$version"
    # Also make the native/unqualified name addressable. Keep the first
    # installed architecture when multiple foreign architectures are present.
    base_package="${package%%:*}"
    if [[ -z "${APT_INSTALLED_VERSION[$base_package]+set}" ]]; then
      APT_INSTALLED_VERSION["$base_package"]="$version"
    fi
  done <<< "$query_output"
  APT_INSTALLED_PACKAGES_LOADED=true
}

load_initial_packages() {
  local contents line package='' architecture=''

  case "$APT_INITIAL_PACKAGES_STATE" in
    available) return 0 ;;
    unavailable) return 1 ;;
  esac

  APT_INITIAL_PACKAGE=()
  if [[ ! -r "$APT_INITIAL_STATUS_FILE" ]]; then
    APT_INITIAL_PACKAGES_STATE='unavailable'
    return 1
  fi

  if [[ "$APT_INITIAL_STATUS_FILE" == *.gz ]]; then
    if ! command -v gzip >/dev/null 2>&1; then
      warn "Cannot read Mint's initial package snapshot because gzip is unavailable: $APT_INITIAL_STATUS_FILE"
      APT_INITIAL_PACKAGES_STATE='unavailable'
      return 1
    fi
    if ! contents="$(gzip -cd -- "$APT_INITIAL_STATUS_FILE" 2>/dev/null)"; then
      warn "Cannot read Mint's initial package snapshot: $APT_INITIAL_STATUS_FILE"
      APT_INITIAL_PACKAGES_STATE='unavailable'
      return 1
    fi
  else
    if ! contents="$(<"$APT_INITIAL_STATUS_FILE")"; then
      warn "Cannot read Mint's initial package snapshot: $APT_INITIAL_STATUS_FILE"
      APT_INITIAL_PACKAGES_STATE='unavailable'
      return 1
    fi
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      'Package: '*)
        if validate_package_name "$package"; then
          APT_INITIAL_PACKAGE["$package"]=1
          if [[ -n "$architecture" ]]; then
            APT_INITIAL_PACKAGE["$package:$architecture"]=1
          fi
        fi
        package="${line#Package: }"
        architecture=''
        ;;
      'Architecture: '*)
        architecture="${line#Architecture: }"
        validate_safe_name "$architecture" || architecture=''
        ;;
    esac
  done <<< "$contents"
  if validate_package_name "$package"; then
    APT_INITIAL_PACKAGE["$package"]=1
    if [[ -n "$architecture" ]]; then
      APT_INITIAL_PACKAGE["$package:$architecture"]=1
    fi
  fi

  if (( ${#APT_INITIAL_PACKAGE[@]} == 0 )); then
    warn "Mint's initial package snapshot contains no valid packages: $APT_INITIAL_STATUS_FILE"
    APT_INITIAL_PACKAGES_STATE='unavailable'
    return 1
  fi
  APT_INITIAL_PACKAGES_STATE='available'
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

discover_selectable_packages() {
  local show_all="$1"
  local manual_output package
  local -a discovered=("${APT_PACKAGES[@]}")

  load_installed_packages
  if [[ "$show_all" == 'true' ]]; then
    discovered+=("${APT_INSTALLED_PACKAGE_NAMES[@]}")
  else
    if ! manual_output="$(apt-mark showmanual 2>&1)"; then
      printf 'Could not read manually marked APT packages: %s\n' \
        "${manual_output:-apt-mark failed without a diagnostic}" >&2
      return 1
    fi
    if ! load_initial_packages; then
      warn "Mint's initial package snapshot is unavailable; showing all manually marked packages instead."
    fi
    while IFS= read -r package || [[ -n "$package" ]]; do
      validate_package_name "$package" || continue
      installed_package_version "$package" >/dev/null || continue
      if [[ "$APT_INITIAL_PACKAGES_STATE" == 'available' \
        && -n "${APT_INITIAL_PACKAGE[$package]+set}" ]]; then
        continue
      fi
      discovered+=("$package")
    done <<< "$manual_output"
  fi

  if (( ${#discovered[@]} > 0 )); then
    printf '%s\n' "${discovered[@]}" | sed '/^$/d' | LC_ALL=C sort -u
  fi
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
  local show_all="$1"
  local package version detail status original_count final_count candidate_output
  local -a candidates=() packages=()

  [[ "$show_all" == 'true' ]] || require_cmd apt-mark
  require_cmd dpkg-query
  load_installed_packages
  candidate_output="$(discover_selectable_packages "$show_all")" \
    || die 'Could not determine selectable APT packages.'
  if [[ -n "$candidate_output" ]]; then
    mapfile -t candidates <<< "$candidate_output"
  fi

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
  if [[ "$show_all" == 'true' ]]; then
    CHECKLIST_TITLE="Select installed APT packages for recovery (${#packages[@]} candidates)"
    CHECKLIST_NOTE="Showing every installed package. Select all affects all ${#packages[@]} candidates, including dependencies and Linux Mint system packages."
  else
    CHECKLIST_TITLE="Select user-installed APT packages for recovery (${#packages[@]} candidates)"
    CHECKLIST_NOTE="Packages from Mint's initial installation are hidden. Use --show-all to include all installed packages."
  fi

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

main() {
  local show_all='false'

  if [[ $# -eq 1 && ( "$1" == '-h' || "$1" == '--help' ) ]]; then
    usage
    return 0
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
      shift
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --show-all) show_all='true' ;;
          -h|--help) usage; return 0 ;;
          *) die "Unknown apt select argument: $1" ;;
        esac
        shift
      done
      select_packages "$show_all"
      ;;
    -h|--help|'')
      usage
      ;;
    *)
      die "Unknown APT configuration command: $1"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
