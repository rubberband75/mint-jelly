#!/usr/bin/env bash

software_installer_options() {
  local wanted="$1" selection
  local -a selected=()
  for selection in "${INSTALLER_OPTION_SELECTIONS[@]}"; do
    [[ "${selection%%:*}" == "$wanted" ]] && selected+=("${selection#*:}")
  done
  printf '%s' "${selected[*]}"
}

software_installer_verification_is_strong() {
  case "${INSTALLER_VERIFICATION[$1]}" in
    sha256-required|signature-required|https-and-pinned-git-commit) return 0 ;;
    *) return 1 ;;
  esac
}

software_run_installer_action() {
  local installer="$1" action="$2" allow_weak="$3" assume_yes="$4" purge="${5:-false}"
  local architecture options option log_dir status
  installer_exists "$installer" || die "Unknown installer '$installer'. Available: ${INSTALLER_NAMES[*]:-none}"
  architecture="$(dpkg --print-architecture)"
  installer_supports_architecture "$installer" "$architecture" \
    || die "Installer '$installer' does not support architecture '$architecture'."
  options="$(software_installer_options "$installer")"
  for option in $options; do
    installer_option_exists "$installer" "$option" \
      || die "Unknown configured option '$option' for installer '$installer'."
  done
  if [[ "$action" == 'install' ]] && env MINT_JELLY_INSTALLER_OPTIONS="$options" \
    "${INSTALLER_RUN_SCRIPT[$installer]}" check >/dev/null 2>&1; then
    env MINT_JELLY_INSTALLER_OPTIONS="$options" "${INSTALLER_RUN_SCRIPT[$installer]}" verify \
      || die "Installer '$installer' is present but failed verification."
    log "Software installer '$installer' is already satisfied."
    return 0
  fi
  if [[ "$action" == 'install' || "$action" == 'update' ]]; then
    if ! software_installer_verification_is_strong "$installer"; then
      warn "Installer '$installer' uses limited verification: ${INSTALLER_VERIFICATION[$installer]}."
      if ! is_interactive && [[ "$allow_weak" != 'true' ]]; then
        die "Non-interactive $action of '$installer' requires --allow-weak-verification."
      fi
    fi
    if [[ "${INSTALLER_INTERACTIVE[$installer]}" == 'yes' && ! -t 0 ]]; then
      die "Installer '$installer' requires an interactive terminal."
    fi
  fi
  log_dir="$MINT_JELLY_STATE_DIR/software/$(date -u '+%Y%m%dT%H%M%S%NZ')/$installer"
  mkdir -p -- "$log_dir"
  chmod 0700 -- "$MINT_JELLY_STATE_DIR" "$MINT_JELLY_STATE_DIR/software" "${log_dir%/*}" "$log_dir"
  log "Running '$action' for ${INSTALLER_DISPLAY_NAME[$installer]}."
  env MINT_JELLY_ASSUME_YES="$assume_yes" \
    MINT_JELLY_INSTALLER_STATE_DIR="$log_dir" \
    MINT_JELLY_INSTALLER_OPTIONS="$options" \
    MINT_JELLY_PURGE="$purge" \
    "${INSTALLER_RUN_SCRIPT[$installer]}" "$action" \
    || die "Installer '$installer' action '$action' failed."
  if [[ "$action" == 'install' || "$action" == 'update' ]]; then
    env MINT_JELLY_INSTALLER_OPTIONS="$options" "${INSTALLER_RUN_SCRIPT[$installer]}" verify \
      || die "Installer '$installer' completed but failed verification."
  else
    if env MINT_JELLY_INSTALLER_OPTIONS="$options" "${INSTALLER_RUN_SCRIPT[$installer]}" check >/dev/null 2>&1; then
      die "Installer '$installer' reported uninstall success but software is still present."
    else
      status=$?
      (( status == 1 )) || die "Could not verify removal of installer '$installer'."
    fi
  fi
}

software_install_apt_packages() {
  local assume_yes="$1" package output
  shift
  local -a missing=() command=(sudo apt-get install)
  for package in "$@"; do
    output="$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)"
    [[ "$output" == 'install ok installed' ]] || missing+=("$package")
  done
  (( ${#missing[@]} > 0 )) || return 0
  [[ "$assume_yes" != 'true' ]] || command+=(--yes)
  command+=("${missing[@]}")
  "${command[@]}" || die 'APT package restoration failed.'
}

software_install_flatpaks() {
  local assume_yes="$1" spec scope remote app branch ref
  shift
  local -a command
  for spec in "$@"; do
    IFS='|' read -r scope remote app branch <<< "$spec"
    ref="$(flatpak info "--$scope" --show-ref "$app" 2>/dev/null || true)"
    [[ "$ref" == app/"$app"/*/"$branch" ]] && continue
    command=(flatpak install "--$scope")
    [[ "$assume_yes" != 'true' ]] || command+=(--noninteractive)
    command+=("$remote" "$app//$branch")
    "${command[@]}" || die "Flatpak restoration failed for '$app'."
  done
}
