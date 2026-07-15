#!/usr/bin/env bash
# Inspect or install the software plan saved in a remote recovery manifest.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/remote.sh
source "$SCRIPT_DIR/lib/remote.sh"
# shellcheck source=lib/recovery.sh
source "$SCRIPT_DIR/lib/recovery.sh"
# shellcheck source=lib/installers.sh
source "$SCRIPT_DIR/lib/installers.sh"

usage() {
  cat <<EOF
Usage:
  ${MINT_JELLY_COMMAND:-mint-jelly software} show [--remote NAME] [--source-host HOSTNAME]
  ${MINT_JELLY_COMMAND:-mint-jelly software} install [--remote NAME] [--source-host HOSTNAME]
      [--apt-only | --installers-only] [--dry-run] [--yes]
      [--allow-platform-mismatch] [--allow-weak-verification]
EOF
}

cleanup() {
  [[ -z "$MANIFEST_TEMP" ]] || rm -f -- "$MANIFEST_TEMP"
  remote_close
}

apt_package_is_installed() {
  local package="$1"
  local output status_code

  if output="$(dpkg-query -W -f='${Status}' "$package" 2>&1)"; then
    [[ "$output" == 'install ok installed' ]]
    return
  else
    status_code=$?
  fi
  (( status_code == 1 )) && return 1
  die "dpkg-query failed for '$package' with status $status_code: ${output:-no diagnostic output}"
}

installer_verification_is_strong() {
  case "${INSTALLER_VERIFICATION[$1]}" in
    sha256-required|signature-required) return 0 ;;
    *) return 1 ;;
  esac
}

installer_verification_description() {
  case "${INSTALLER_VERIFICATION[$1]}" in
    sha256-required) printf 'upstream SHA-256 required' ;;
    signature-required) printf 'upstream signature required' ;;
    https-and-deb-metadata) printf 'HTTPS and Debian metadata; no published checksum' ;;
    https-and-archive-layout) printf 'HTTPS and archive validation; no published checksum' ;;
    *) printf '%s' "${INSTALLER_VERIFICATION[$1]}" ;;
  esac
}

classify_installer() {
  local installer="$1"
  local status

  if ! installer_supports_architecture "$installer" "$CURRENT_ARCHITECTURE"; then
    INCOMPATIBLE_INSTALLERS+=("$installer")
    return
  fi

  if "${INSTALLER_RUN_SCRIPT[$installer]}" check >/dev/null 2>&1; then
    if "${INSTALLER_RUN_SCRIPT[$installer]}" verify >/dev/null 2>&1; then
      INSTALLED_INSTALLERS+=("$installer")
    else
      CHECK_FAILED_INSTALLERS+=("$installer")
    fi
    return
  else
    status=$?
  fi
  case "$status" in
    1)
      MISSING_INSTALLERS+=("$installer")
      installer_verification_is_strong "$installer" \
        || WEAK_VERIFICATION_INSTALLERS+=("$installer")
      ;;
    *) CHECK_FAILED_INSTALLERS+=("$installer") ;;
  esac
}

print_list() {
  local label="$1"
  shift
  local value

  printf '%s (%d):\n' "$label" "$#"
  if (( $# == 0 )); then
    printf '  none\n'
    return
  fi
  for value in "$@"; do
    printf '  %s\n' "$value"
  done
}

print_installer_list() {
  local label="$1"
  shift
  local installer verification

  printf '%s (%d):\n' "$label" "$#"
  if (( $# == 0 )); then
    printf '  none\n'
    return
  fi
  for installer in "$@"; do
    verification="$(installer_verification_description "$installer")"
    printf '  %s - %s [verification: %s]\n' \
      "$installer" "${INSTALLER_DISPLAY_NAME[$installer]}" "$verification"
  done
}

print_plan() {
  printf 'Recovery software plan:\n'
  printf '  Source host: %s\n' "$SOURCE_HOST"
  printf '  Remote:      %s\n' "$SELECTED_REMOTE"
  printf '  Recorded:    %s %s (%s, Ubuntu %s)\n' \
    "$RECOVERY_OS_ID" "$RECOVERY_OS_VERSION" \
    "$RECOVERY_ARCHITECTURE" "$RECOVERY_UBUNTU_CODENAME"
  printf '  Current:     %s %s (%s, Ubuntu %s)\n\n' \
    "$CURRENT_OS_ID" "$CURRENT_OS_VERSION" \
    "$CURRENT_ARCHITECTURE" "$CURRENT_UBUNTU_CODENAME"

  if [[ "$PLATFORM_MATCHES" != 'true' ]]; then
    warn 'The recovery plan was created on a different operating-system platform.'
    printf '\n'
  fi

  if [[ "$INSTALLERS_ONLY" != 'true' ]]; then
    print_list 'APT packages already installed' "${INSTALLED_APT_PACKAGES[@]}"
    print_list 'APT packages to install' "${MISSING_APT_PACKAGES[@]}"
    printf '\n'
  fi
  if [[ "$APT_ONLY" != 'true' ]]; then
    print_installer_list 'Special installers already satisfied' "${INSTALLED_INSTALLERS[@]}"
    print_installer_list 'Special installers to run' "${MISSING_INSTALLERS[@]}"
    print_installer_list 'Installers incompatible with this architecture' "${INCOMPATIBLE_INSTALLERS[@]}"
    print_installer_list 'Installers whose local check or verification failed' "${CHECK_FAILED_INSTALLERS[@]}"
    if (( ${#WEAK_VERIFICATION_INSTALLERS[@]} > 0 )); then
      printf '\nSecurity note: these installers have no vendor-published artifact checksum: %s\n' \
        "${WEAK_VERIFICATION_INSTALLERS[*]}"
      printf 'They will rely on HTTPS plus package or archive validation.\n'
    fi
  fi
}

confirm_install() {
  local answer

  [[ "$ASSUME_YES" == 'true' ]] && return 0
  is_interactive \
    || die 'Software installation requires confirmation. Re-run with --yes only after reviewing `mint-jelly software show`.'
  printf '\nInstall the missing software shown above? [y/N]: '
  IFS= read -r answer
  case "${answer,,}" in
    y|yes) ;;
    *) die 'Software installation cancelled.' ;;
  esac
}

run_logged() {
  local log_file="$1"
  shift
  local -a pipeline_status=()

  require_cmd tee
  set +e
  "$@" 2>&1 | tee -a "$log_file"
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  (( pipeline_status[0] == 0 )) || return "${pipeline_status[0]}"
  if (( pipeline_status[1] != 0 )); then
    warn "Could not write the complete command log: $log_file"
    return "${pipeline_status[1]}"
  fi
  return 0
}

ACTION=''
SELECTED_REMOTE=''
SOURCE_HOST=''
APT_ONLY='false'
INSTALLERS_ONLY='false'
DRY_RUN='false'
ASSUME_YES='false'
ALLOW_PLATFORM_MISMATCH='false'
ALLOW_WEAK_VERIFICATION='false'
MANIFEST_TEMP=''
INSTALLED_APT_PACKAGES=()
MISSING_APT_PACKAGES=()
INSTALLED_INSTALLERS=()
MISSING_INSTALLERS=()
INCOMPATIBLE_INSTALLERS=()
CHECK_FAILED_INSTALLERS=()
WEAK_VERIFICATION_INSTALLERS=()
FAILED_COMPONENTS=()

ACTION="${1-}"
case "$ACTION" in
  show|install) shift ;;
  -h|--help|'') usage; exit 0 ;;
  *) die "Unknown software command: $ACTION" ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote)
      [[ $# -ge 2 ]] || die '--remote requires a name.'
      SELECTED_REMOTE="$2"
      shift 2
      ;;
    --source-host)
      [[ $# -ge 2 ]] || die '--source-host requires a hostname.'
      SOURCE_HOST="$2"
      shift 2
      ;;
    --apt-only) APT_ONLY='true'; shift ;;
    --installers-only) INSTALLERS_ONLY='true'; shift ;;
    --dry-run) DRY_RUN='true'; shift ;;
    --yes) ASSUME_YES='true'; shift ;;
    --allow-platform-mismatch) ALLOW_PLATFORM_MISMATCH='true'; shift ;;
    --allow-weak-verification) ALLOW_WEAK_VERIFICATION='true'; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "$APT_ONLY" != 'true' || "$INSTALLERS_ONLY" != 'true' ]] \
  || die '--apt-only and --installers-only cannot be used together.'
if [[ "$ACTION" == 'show' ]]; then
  [[ "$APT_ONLY" == 'false' && "$INSTALLERS_ONLY" == 'false' \
    && "$DRY_RUN" == 'false' && "$ASSUME_YES" == 'false' \
    && "$ALLOW_PLATFORM_MISMATCH" == 'false' \
    && "$ALLOW_WEAK_VERIFICATION" == 'false' ]] \
    || die 'show accepts only --remote and --source-host.'
fi
if [[ "$ALLOW_WEAK_VERIFICATION" == 'true' ]]; then
  [[ "$APT_ONLY" != 'true' ]] \
    || die '--allow-weak-verification cannot be used with --apt-only.'
  [[ "$ASSUME_YES" == 'true' ]] \
    || die '--allow-weak-verification is only valid with --yes.'
fi
(( EUID != 0 )) || die 'Run Mint Jelly as your desktop user, not as root.'

require_cmd dpkg-query
require_cmd flock
require_cmd hostname
require_initialized_config
config_read
[[ "$APT_ONLY" == 'true' ]] || load_installers

if [[ -z "$SELECTED_REMOTE" ]]; then
  [[ -n "$DEFAULT_REMOTE" ]] \
    || die 'No default remote is configured. Run: mint-jelly config remote add'
  SELECTED_REMOTE="$DEFAULT_REMOTE"
fi
remote_exists "$SELECTED_REMOTE" \
  || die "Unknown backup remote: $SELECTED_REMOTE"
[[ -n "$SOURCE_HOST" ]] || SOURCE_HOST="$(hostname)"
validate_safe_name "$SOURCE_HOST" || die "Unsafe source hostname: $SOURCE_HOST"

recovery_reset
recovery_populate_platform "$(hostname)"
CURRENT_OS_ID="$RECOVERY_OS_ID"
CURRENT_OS_VERSION="$RECOVERY_OS_VERSION"
CURRENT_UBUNTU_CODENAME="$RECOVERY_UBUNTU_CODENAME"
CURRENT_ARCHITECTURE="$RECOVERY_ARCHITECTURE"

ensure_config_dir
exec 9>"$MINT_JELLY_CONFIG_DIR/operation.lock"
flock -n 9 || die 'Another Mint Jelly backup, restore, or software operation is already running.'
MANIFEST_TEMP="$(mktemp "${MINT_JELLY_CONFIG_DIR}/.software-recovery.XXXXXX")"
chmod 0600 -- "$MANIFEST_TEMP"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

remote_open "$SELECTED_REMOTE" "$SOURCE_HOST" read
remote_lock_acquire shared
remote_read_recovery_manifest > "$MANIFEST_TEMP" \
  || die "No valid recovery manifest exists for '$SOURCE_HOST'. Run a new backup with this version of Mint Jelly first."
recovery_read "$MANIFEST_TEMP"
[[ "$RECOVERY_HOSTNAME" == "$SOURCE_HOST" ]] \
  || die "Recovery manifest hostname '$RECOVERY_HOSTNAME' does not match requested source host '$SOURCE_HOST'."
remote_lock_verify
remote_lock_release || die 'Could not release the shared remote operation lock.'
remote_close

PLATFORM_MATCHES='false'
if [[ "$RECOVERY_OS_ID" == "$CURRENT_OS_ID" \
  && "$RECOVERY_OS_VERSION" == "$CURRENT_OS_VERSION" \
  && "$RECOVERY_UBUNTU_CODENAME" == "$CURRENT_UBUNTU_CODENAME" \
  && "$RECOVERY_ARCHITECTURE" == "$CURRENT_ARCHITECTURE" ]]; then
  PLATFORM_MATCHES='true'
fi

if [[ "$INSTALLERS_ONLY" != 'true' ]]; then
  for package in "${RECOVERY_APT_PACKAGES[@]}"; do
    if apt_package_is_installed "$package"; then
      INSTALLED_APT_PACKAGES+=("$package")
    else
      MISSING_APT_PACKAGES+=("$package")
    fi
  done
fi
if [[ "$APT_ONLY" != 'true' ]]; then
  INSTALLERS=("${RECOVERY_INSTALLERS[@]}")
  require_configured_installers_available
  for installer in "${INSTALLERS[@]}"; do
    classify_installer "$installer"
  done
fi

print_plan
[[ "$ACTION" == 'install' ]] || exit 0
if [[ "$PLATFORM_MATCHES" != 'true' && "$ALLOW_PLATFORM_MISMATCH" != 'true' ]]; then
  die 'Refusing software installation on a different platform. Use --allow-platform-mismatch only after reviewing the plan.'
fi
if [[ "$DRY_RUN" == 'true' ]]; then
  log 'Dry run complete; no package downloads, sudo, or installation commands were used.'
  exit 0
fi

if [[ "$ASSUME_YES" == 'true' \
  && "$ALLOW_WEAK_VERIFICATION" != 'true' \
  && ${#WEAK_VERIFICATION_INSTALLERS[@]} -gt 0 ]]; then
  die "Unattended installation of limited-verification installers requires --allow-weak-verification: ${WEAK_VERIFICATION_INSTALLERS[*]}"
fi

confirm_install
install_count=$((${#MISSING_APT_PACKAGES[@]} + ${#MISSING_INSTALLERS[@]}))
if (( install_count == 0 )); then
  if (( ${#INCOMPATIBLE_INSTALLERS[@]} + ${#CHECK_FAILED_INSTALLERS[@]} > 0 )); then
    die 'Nothing can be installed until the installer errors above are resolved.'
  fi
  log 'All selected software is already installed.'
  exit 0
fi

LOG_DIR="$MINT_JELLY_STATE_DIR/software/$(date -u '+%Y%m%dT%H%M%S%NZ')"
mkdir -p -- "$LOG_DIR"
chmod 0700 -- "$MINT_JELLY_STATE_DIR" "$MINT_JELLY_STATE_DIR/software" "$LOG_DIR"

needs_sudo='false'
(( ${#MISSING_APT_PACKAGES[@]} > 0 )) && needs_sudo='true'
for installer in "${MISSING_INSTALLERS[@]}"; do
  [[ "${INSTALLER_PRIVILEGE[$installer]}" != 'system' ]] || needs_sudo='true'
done
if [[ "$needs_sudo" == 'true' ]]; then
  require_cmd sudo
  sudo -v || die 'Could not acquire sudo credentials.'
fi

if (( ${#MISSING_APT_PACKAGES[@]} > 0 )); then
  require_cmd apt-get
  log 'Refreshing APT package indexes...'
  if ! run_logged "$LOG_DIR/apt.log" \
    sudo env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none \
      apt-get -o Dpkg::Use-Pty=0 update; then
    warn 'APT package index refresh failed; skipping the configured APT package transaction.'
    FAILED_COMPONENTS+=('apt')
  else
    log "Installing APT packages: ${MISSING_APT_PACKAGES[*]}"
    if ! run_logged "$LOG_DIR/apt.log" \
      sudo env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none \
        apt-get -o Dpkg::Use-Pty=0 \
          -o Dpkg::Options::=--force-confold \
          install --yes "${MISSING_APT_PACKAGES[@]}"; then
      warn 'APT package installation failed.'
      FAILED_COMPONENTS+=('apt')
    fi
  fi
fi

for installer in "${MISSING_INSTALLERS[@]}"; do
  log "Running installer '$installer': ${INSTALLER_DESCRIPTION[$installer]}"
  if [[ "${INSTALLER_INTERACTIVE[$installer]}" == 'yes' ]] \
    && ! is_interactive; then
    warn "Installer '$installer' requires an interactive terminal; skipping it."
    FAILED_COMPONENTS+=("$installer")
    continue
  fi
  if [[ "${INSTALLER_VERIFICATION[$installer]}" == *tls* \
    || "${INSTALLER_VERIFICATION[$installer]}" == *https* ]]; then
    warn "Installer '$installer' relies on ${INSTALLER_VERIFICATION[$installer]} verification."
  fi
  mkdir -p -- "$LOG_DIR/$installer"
  chmod 0700 -- "$LOG_DIR/$installer"
  install_succeeded='false'
  if [[ "${INSTALLER_INTERACTIVE[$installer]}" == 'yes' ]]; then
    printf 'Interactive installer output was attached directly to the terminal and was not captured.\n' \
      >> "$LOG_DIR/$installer.log"
    if env MINT_JELLY_ASSUME_YES="$ASSUME_YES" \
      MINT_JELLY_INSTALLER_STATE_DIR="$LOG_DIR/$installer" \
      "${INSTALLER_RUN_SCRIPT[$installer]}" install; then
      install_succeeded='true'
    fi
  elif run_logged "$LOG_DIR/$installer.log" \
    env MINT_JELLY_ASSUME_YES="$ASSUME_YES" \
      MINT_JELLY_INSTALLER_STATE_DIR="$LOG_DIR/$installer" \
      "${INSTALLER_RUN_SCRIPT[$installer]}" install; then
    install_succeeded='true'
  fi
  if [[ "$install_succeeded" != 'true' ]]; then
    warn "Installer '$installer' failed."
    FAILED_COMPONENTS+=("$installer")
    continue
  fi
  if ! "${INSTALLER_RUN_SCRIPT[$installer]}" verify >> "$LOG_DIR/$installer.log" 2>&1; then
    warn "Installer '$installer' did not pass post-install verification."
    FAILED_COMPONENTS+=("$installer")
    continue
  fi
  log "Installer '$installer' completed successfully."
done

for installer in "${INCOMPATIBLE_INSTALLERS[@]}" "${CHECK_FAILED_INSTALLERS[@]}"; do
  [[ -n "$installer" ]] && FAILED_COMPONENTS+=("$installer")
done

if (( ${#FAILED_COMPONENTS[@]} > 0 )); then
  warn "Software installation finished with failures: ${FAILED_COMPONENTS[*]}"
  warn "Logs: $LOG_DIR"
  exit 1
fi
log "Software installation completed successfully. Logs: $LOG_DIR"
