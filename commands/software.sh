#!/usr/bin/env bash

set -euo pipefail
umask 077
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/installers.sh"
source "$SCRIPT_DIR/lib/software-actions.sh"
source "$SCRIPT_DIR/lib/application-profiles.sh"
source "$SCRIPT_DIR/lib/checklist.sh"

usage() {
  cat <<'EOF'
Usage:
  mint-jelly software install INSTALLER... [--allow-weak-verification]
  mint-jelly software update [INSTALLER...] [--allow-weak-verification]
  mint-jelly software uninstall INSTALLER... [--purge] [--yes]
  mint-jelly software config
  mint-jelly software list
  mint-jelly software list-remote [--remote NAME] [--source-host HOSTNAME]
  mint-jelly software backup [--remote NAME] [--dry-run]
  mint-jelly software restore [restore options]

update with no installer names updates every configured bundled installer.
--purge removes application configuration as well as the installed software.
EOF
}

array_has() { local wanted="$1" value; shift; for value in "$@"; do [[ "$value" == "$wanted" ]] && return 0; done; return 1; }

track_installer() {
  local installer="$1"
  if ! array_has "$installer" "${INSTALLERS[@]}"; then INSTALLERS+=("$installer"); fi
  application_auto_select_profiles
  config_write
}

untrack_installer() {
  local removed="$1" purge="$2" value profile
  local -a kept=() kept_options=() kept_apps=()
  for value in "${INSTALLERS[@]}"; do [[ "$value" == "$removed" ]] || kept+=("$value"); done
  for value in "${INSTALLER_OPTION_SELECTIONS[@]}"; do [[ "${value%%:*}" == "$removed" ]] || kept_options+=("$value"); done
  INSTALLERS=("${kept[@]}"); INSTALLER_OPTION_SELECTIONS=("${kept_options[@]}")
  if [[ "$purge" == true ]]; then
    for profile in "${APPLICATIONS[@]}"; do
      if [[ "${APPLICATION_PROFILE_INSTALLER[$profile]-}" == "$removed" ]] \
        && ! application_profile_is_configured_software "$profile"; then
        continue
      fi
      kept_apps+=("$profile")
    done
    APPLICATIONS=("${kept_apps[@]}")
  fi
  config_write
}

configure_application_profiles() {
  local profile status
  local_operation_lock_acquire; trap local_operation_lock_release RETURN
  config_read; application_auto_select_profiles
  CHECKLIST_IDS=("${APPLICATION_PROFILE_IDS[@]}")
  CHECKLIST_LABELS=(); CHECKLIST_DETAILS=(); CHECKLIST_INITIAL_SELECTED=()
  for profile in "${APPLICATION_PROFILE_IDS[@]}"; do
    CHECKLIST_LABELS+=("${APPLICATION_PROFILE_NAME[$profile]}")
    if application_profile_is_configured_software "$profile"; then
      CHECKLIST_DETAILS+=('[selected automatically for configured software]')
      CHECKLIST_INITIAL_SELECTED+=(1)
    elif array_has "$profile" "${APPLICATIONS[@]}"; then
      CHECKLIST_DETAILS+=('[standalone profile]'); CHECKLIST_INITIAL_SELECTED+=(1)
    else
      CHECKLIST_DETAILS+=('[standalone profile]'); CHECKLIST_INITIAL_SELECTED+=(0)
    fi
  done
  CHECKLIST_TITLE='Select application configuration profiles'
  CHECKLIST_NOTE='Profiles associated with configured software remain selected automatically.'
  if checklist_run; then
    APPLICATIONS=("${CHECKLIST_RESULT[@]}")
    application_auto_select_profiles
    config_write
    log "Configured ${#APPLICATIONS[@]} application profile(s)."
  else
    status=$?; ((status == 1)) || return "$status"
  fi
  local_operation_lock_release; trap - RETURN
}

configure_software() {
  is_interactive || die 'software config requires an interactive terminal.'
  config_initialize_if_missing
  printf '\nAPT packages\n'
  "$SCRIPT_DIR/mint-jelly" apt config
  printf '\nFlatpak applications\n'
  "$SCRIPT_DIR/mint-jelly" flatpak config
  printf '\nBundled installers\n'
  "$SCRIPT_DIR/configure-installers.sh"
  printf '\nApplication configuration\n'
  configure_application_profiles
}

action="${1-}"; [[ -z "$action" ]] || shift
case "$action" in
  install|update|uninstall)
    allow_weak='false'; assume_yes='false'; purge='false'; names=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --allow-weak-verification) allow_weak='true' ;;
        --yes) assume_yes='true' ;;
        --purge) purge='true' ;;
        --*) die "Unknown software $action argument: $1" ;;
        *) names+=("$1") ;;
      esac
      shift
    done
    [[ "$action" == uninstall || "$purge" == false ]] || die '--purge is valid only with software uninstall.'
    [[ "$action" == uninstall || "$assume_yes" == false ]] || die '--yes is valid only with software uninstall.'
    (( EUID != 0 )) || die 'Run Mint Jelly as your desktop user, not as root.'
    local_operation_lock_acquire; trap local_operation_lock_release EXIT
    config_initialize_if_missing; config_read; load_installers; require_cmd dpkg
    if [[ "$action" == update && ${#names[@]} -eq 0 ]]; then names=("${INSTALLERS[@]}"); fi
    (( ${#names[@]} > 0 )) || die "software $action requires at least one installer name."
    for installer in "${names[@]}"; do
      if [[ "$action" != install ]] && ! array_has "$installer" "${INSTALLERS[@]}"; then
        die "Installer '$installer' is not configured."
      fi
      if [[ "$action" == uninstall && "$assume_yes" != true ]]; then
        if ! is_interactive; then die 'Software uninstall requires --yes when non-interactive.'; fi
        printf 'Uninstall %s%s? [y/N]: ' "$installer" "$([[ "$purge" == true ]] && printf ' and purge its configuration')"
        IFS= read -r answer
        [[ "${answer,,}" == y || "${answer,,}" == yes ]] || die 'Uninstall cancelled.'
      fi
      software_run_installer_action "$installer" "$action" "$allow_weak" "$assume_yes" "$purge"
      if [[ "$action" == install ]]; then track_installer "$installer"; fi
      if [[ "$action" == uninstall ]]; then untrack_installer "$installer" "$purge"; fi
    done
    ;;
  list)
    [[ $# -eq 0 ]] || die 'software list does not accept arguments.'
    [[ -f "$MINT_JELLY_CONFIG_FILE" ]] || { printf 'No software configured.\n'; exit 0; }
    config_read; application_auto_select_profiles
    printf 'APT packages:\n'; for value in "${APT_PACKAGES[@]}"; do printf '  %s\n' "$value"; done
    printf 'Flatpak applications:\n'; for value in "${FLATPAK_APPS[@]}"; do printf '  %s\n' "$value"; done
    printf 'Bundled installers:\n'; for value in "${INSTALLERS[@]}"; do printf '  %s\n' "$value"; done
    printf 'Application configuration profiles:\n'; for value in "${APPLICATIONS[@]}"; do printf '  %s\n' "$value"; done
    ;;
  config)
    [[ $# -eq 0 ]] || die 'software config does not accept arguments.'
    configure_software
    ;;
  backup) MINT_JELLY_COMMAND='mint-jelly software backup' exec "$SCRIPT_DIR/backup.sh" --domain software "$@" ;;
  restore) MINT_JELLY_COMMAND='mint-jelly software restore' exec "$SCRIPT_DIR/restore.sh" --domain software "$@" ;;
  list-remote) MINT_JELLY_COMMAND='mint-jelly software list-remote' exec "$SCRIPT_DIR/restore.sh" --domain software --list "$@" ;;
  -h|--help|'') usage ;;
  *) die "Unknown software command: $action" ;;
esac
