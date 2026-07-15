#!/usr/bin/env bash

set -Eeuo pipefail

readonly INSTALLER_NAME='Google Cloud CLI'
readonly BASE_PACKAGE='google-cloud-cli'
readonly KEY_URL='https://packages.cloud.google.com/apt/doc/apt-key.gpg'
readonly KEYRING_PATH='/usr/share/keyrings/cloud.google.gpg'
readonly SOURCE_FILE='/etc/apt/sources.list.d/google-cloud-sdk.list'
readonly SOURCE_LINE='deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main'
readonly MAX_KEY_BYTES='1048576'

readonly -a ALLOWED_OPTIONS=(
  google-cloud-cli-anthos-auth
  google-cloud-cli-app-engine-go
  google-cloud-cli-app-engine-grpc
  google-cloud-cli-app-engine-java
  google-cloud-cli-app-engine-python
  google-cloud-cli-app-engine-python-extras
  google-cloud-cli-bigtable-emulator
  google-cloud-cli-cbt
  google-cloud-cli-cloud-build-local
  google-cloud-cli-cloud-run-proxy
  google-cloud-cli-config-connector
  google-cloud-cli-datastore-emulator
  google-cloud-cli-firestore-emulator
  google-cloud-cli-gke-gcloud-auth-plugin
  google-cloud-cli-kpt
  google-cloud-cli-kubectl-oidc
  google-cloud-cli-local-extract
  google-cloud-cli-minikube
  google-cloud-cli-nomos
  google-cloud-cli-pubsub-emulator
  google-cloud-cli-skaffold
  google-cloud-cli-spanner-emulator
  google-cloud-cli-terraform-tools
  google-cloud-cli-tests
  kubectl
)

SELECTED_OPTIONS=()
INSTALL_PACKAGES=()
TEMP_DIR=''
PENDING_KEY=''
PENDING_SOURCE=''
BACKUP_KEY=''
BACKUP_SOURCE=''
REPOSITORY_TRANSACTION_ACTIVE='false'
HAD_KEY='false'
HAD_SOURCE='false'
NEW_KEY_MAY_EXIST='false'
NEW_SOURCE_MAY_EXIST='false'

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

path_permissions_are_safe() {
  local mode permissions

  mode="$(stat -c '%a' -- "$1" 2>/dev/null)" || return 1
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  permissions=$((8#$mode))
  (( (permissions & 8#022) == 0 ))
}

path_is_root_owned() {
  [[ "$(stat -c '%u' -- "$1" 2>/dev/null)" == '0' ]]
}

option_is_allowed() {
  local expected="$1"
  local option

  for option in "${ALLOWED_OPTIONS[@]}"; do
    [[ "$option" == "$expected" ]] && return 0
  done
  return 1
}

load_selected_options() {
  local option
  local -a requested=()
  local -A seen=()

  SELECTED_OPTIONS=()
  INSTALL_PACKAGES=("$BASE_PACKAGE")
  read -r -a requested <<< "${MINT_JELLY_INSTALLER_OPTIONS:-}"
  for option in "${requested[@]}"; do
    option_is_allowed "$option" \
      || die "Unsupported $INSTALLER_NAME option: $option"
    [[ -z "${seen[$option]+set}" ]] \
      || die "Duplicate $INSTALLER_NAME option: $option"
    seen["$option"]=1
    SELECTED_OPTIONS+=("$option")
    INSTALL_PACKAGES+=("$option")
  done
}

validate_key_file() {
  local key_file="$1"
  local key_data gnupg_home status

  [[ -f "$key_file" && ! -L "$key_file" && -s "$key_file" ]] || return 1
  gnupg_home="$(mktemp -d "${TMPDIR:-/tmp}/mint-jelly-gpg.XXXXXXXX")" \
    || return 1
  chmod 0700 -- "$gnupg_home" || {
    rm -rf -- "$gnupg_home"
    return 1
  }
  if key_data="$(gpg --batch --homedir "$gnupg_home" \
    --show-keys --with-colons -- "$key_file" 2>/dev/null)"; then
    status=0
  else
    status=$?
  fi
  rm -rf -- "$gnupg_home"
  ((status == 0)) || return 1
  grep -Eq '^pub:[^:]*:[^:]*:[^:]*:[A-Fa-f0-9]+:' <<< "$key_data" \
    || return 1
  grep -Eq '^fpr:::::::::[A-Fa-f0-9]{40,64}:$' <<< "$key_data" \
    || return 1
  grep -Fq ':Artifact Registry Repository Signer <artifact-registry-repository-signer@google.com>:' \
    <<< "$key_data" || return 1
}

source_file_is_exact() {
  local -a lines=()

  [[ -f "$SOURCE_FILE" && ! -L "$SOURCE_FILE" ]] || return 1
  mapfile -t lines < "$SOURCE_FILE"
  ((${#lines[@]} == 1)) && [[ "${lines[0]}" == "$SOURCE_LINE" ]]
}

no_duplicate_google_sources() {
  local file
  local -a source_files=()

  shopt -s nullglob
  source_files=(
    /etc/apt/sources.list
    /etc/apt/sources.list.d/*.list
    /etc/apt/sources.list.d/*.sources
  )
  shopt -u nullglob
  for file in "${source_files[@]}"; do
    [[ "$file" != "$SOURCE_FILE" && -r "$file" ]] || continue
    if grep -Eq 'packages[.]cloud[.]google[.]com/apt' "$file" 2>/dev/null \
      && grep -Eq 'cloud-sdk' "$file" 2>/dev/null; then
      printf 'Error: Duplicate Google Cloud APT repository configuration found: %s\n' \
        "$file" >&2
      return 1
    fi
  done
}

validate_repository_configuration() {
  local missing='false'

  no_duplicate_google_sources || return 2

  if [[ ! -e "$SOURCE_FILE" && ! -L "$SOURCE_FILE" ]]; then
    missing='true'
  elif ! source_file_is_exact \
    || ! path_permissions_are_safe "$SOURCE_FILE" \
    || ! path_is_root_owned "$SOURCE_FILE"; then
    printf 'Error: Google Cloud APT source is unexpected or unsafe: %s\n' "$SOURCE_FILE" >&2
    return 2
  fi

  if [[ ! -e "$KEYRING_PATH" && ! -L "$KEYRING_PATH" ]]; then
    missing='true'
  elif [[ ! -f "$KEYRING_PATH" || -L "$KEYRING_PATH" ]] \
    || ! path_permissions_are_safe "$KEYRING_PATH" \
    || ! path_is_root_owned "$KEYRING_PATH" \
    || ! validate_key_file "$KEYRING_PATH"; then
    printf 'Error: Google Cloud APT keyring is unexpected or unsafe: %s\n' "$KEYRING_PATH" >&2
    return 2
  fi

  [[ "$missing" == 'false' ]] || return 1
}

package_is_installed() {
  local package="$1"
  local output status

  if output="$(dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null)"; then
    [[ "$output" == 'ii ' ]]
    return
  else
    status=$?
  fi
  ((status == 1)) && return 1
  return "$status"
}

check_installation() {
  local package status
  local missing='false'

  load_selected_options
  command -v dpkg-query >/dev/null 2>&1 || {
    printf 'Error: Required command not found: dpkg-query\n' >&2
    return 2
  }
  command -v gpg >/dev/null 2>&1 || {
    printf 'Error: Required command not found: gpg\n' >&2
    return 2
  }
  command -v grep >/dev/null 2>&1 || {
    printf 'Error: Required command not found: grep\n' >&2
    return 2
  }
  command -v mktemp >/dev/null 2>&1 || {
    printf 'Error: Required command not found: mktemp\n' >&2
    return 2
  }

  if validate_repository_configuration; then
    :
  else
    status=$?
    ((status == 1)) || return "$status"
    missing='true'
  fi
  for package in "${INSTALL_PACKAGES[@]}"; do
    if package_is_installed "$package"; then
      :
    else
      status=$?
      ((status == 1)) || return "$status"
      missing='true'
    fi
  done
  [[ "$missing" == 'false' ]]
}

verify_package() {
  local package="$1"
  local architecture integrity_output version

  package_is_installed "$package" || return $?
  version="$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null || true)"
  architecture="$(dpkg-query -W -f='${Architecture}' "$package" 2>/dev/null || true)"
  [[ -n "$version" ]] && dpkg --validate-version "$version" >/dev/null 2>&1 \
    || return 1
  [[ "$architecture" == 'amd64' || "$architecture" == 'all' ]] || return 1
  if integrity_output="$(dpkg --verify "$package" 2>&1)"; then
    [[ -z "$integrity_output" ]]
  else
    return 1
  fi
}

verify_installation() {
  local package rc version package_files

  if check_installation; then
    :
  else
    rc=$?
    if ((rc == 1)); then
      printf '%s or one of its selected options is not fully installed.\n' \
        "$INSTALLER_NAME" >&2
    fi
    return "$rc"
  fi
  command -v dpkg >/dev/null 2>&1 || {
    printf 'Error: Required command not found: dpkg\n' >&2
    return 2
  }
  for package in "${INSTALL_PACKAGES[@]}"; do
    verify_package "$package" || {
      printf 'Error: Installed package failed verification: %s\n' "$package" >&2
      return 2
    }
  done
  [[ -L /usr/bin/gcloud \
    && "$(readlink -- /usr/bin/gcloud 2>/dev/null || true)" == '../lib/google-cloud-sdk/bin/gcloud' \
    && -f /usr/lib/google-cloud-sdk/bin/gcloud \
    && ! -L /usr/lib/google-cloud-sdk/bin/gcloud \
    && -x /usr/lib/google-cloud-sdk/bin/gcloud ]] || {
    printf 'Error: The installed Google Cloud CLI has no safe /usr/bin/gcloud executable.\n' >&2
    return 2
  }
  package_files="$(dpkg-query -L "$BASE_PACKAGE" 2>/dev/null)" || return 2
  grep -Fxq '/usr/bin/gcloud' <<< "$package_files" || {
    printf 'Error: /usr/bin/gcloud is not owned by the installed %s package.\n' \
      "$BASE_PACKAGE" >&2
    return 2
  }
  grep -Fxq '/usr/lib/google-cloud-sdk/bin/gcloud' <<< "$package_files" || {
    printf 'Error: The resolved gcloud executable is not owned by the installed %s package.\n' \
      "$BASE_PACKAGE" >&2
    return 2
  }
  version="$(dpkg-query -W -f='${Version}' "$BASE_PACKAGE")"
  printf '%s is installed (version %s; %d optional package(s)).\n' \
    "$INSTALLER_NAME" "$version" "${#SELECTED_OPTIONS[@]}"
}

rollback_repository_transaction() {
  local rollback_ok='true'

  [[ "$REPOSITORY_TRANSACTION_ACTIVE" == 'true' ]] || return 0
  warn 'Rolling back the interrupted Google Cloud APT repository update.'

  if [[ "$NEW_SOURCE_MAY_EXIST" == 'true' ]]; then
    sudo -n -- rm -f -- "$SOURCE_FILE" 2>/dev/null || rollback_ok='false'
  fi
  if [[ "$HAD_SOURCE" == 'true' && ( -e "$BACKUP_SOURCE" || -L "$BACKUP_SOURCE" ) ]]; then
    sudo -n -- mv -- "$BACKUP_SOURCE" "$SOURCE_FILE" 2>/dev/null || rollback_ok='false'
  fi
  if [[ "$NEW_KEY_MAY_EXIST" == 'true' ]]; then
    sudo -n -- rm -f -- "$KEYRING_PATH" 2>/dev/null || rollback_ok='false'
  fi
  if [[ "$HAD_KEY" == 'true' && ( -e "$BACKUP_KEY" || -L "$BACKUP_KEY" ) ]]; then
    sudo -n -- mv -- "$BACKUP_KEY" "$KEYRING_PATH" 2>/dev/null || rollback_ok='false'
  fi
  [[ -z "$PENDING_SOURCE" || ( ! -e "$PENDING_SOURCE" && ! -L "$PENDING_SOURCE" ) ]] \
    || sudo -n -- rm -f -- "$PENDING_SOURCE" 2>/dev/null || rollback_ok='false'
  [[ -z "$PENDING_KEY" || ( ! -e "$PENDING_KEY" && ! -L "$PENDING_KEY" ) ]] \
    || sudo -n -- rm -f -- "$PENDING_KEY" 2>/dev/null || rollback_ok='false'

  [[ "$rollback_ok" == 'true' ]] || {
    warn "Automatic rollback was incomplete. Inspect $KEYRING_PATH and $SOURCE_FILE."
    return 1
  }
}

cleanup() {
  local status=$?

  trap - EXIT HUP INT TERM
  if ! rollback_repository_transaction; then
    ((status == 0)) && status=2
  fi
  [[ -z "$TEMP_DIR" || ! -d "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"
  exit "$status"
}

activate_repository() {
  local new_key="$1"
  local new_source="$2"

  PENDING_KEY="/usr/share/keyrings/.mint-jelly-cloud-google-new-$$"
  PENDING_SOURCE="/etc/apt/sources.list.d/.mint-jelly-google-cloud-new-$$"
  BACKUP_KEY="/usr/share/keyrings/.mint-jelly-cloud-google-old-$$"
  BACKUP_SOURCE="/etc/apt/sources.list.d/.mint-jelly-google-cloud-old-$$"

  if [[ -e "$PENDING_KEY" || -L "$PENDING_KEY" \
    || -e "$PENDING_SOURCE" || -L "$PENDING_SOURCE" \
    || -e "$BACKUP_KEY" || -L "$BACKUP_KEY" \
    || -e "$BACKUP_SOURCE" || -L "$BACKUP_SOURCE" ]]; then
    die 'Refusing to overwrite an existing Google Cloud repository transaction path'
  fi
  [[ ! -e "$KEYRING_PATH" || ( -f "$KEYRING_PATH" && ! -L "$KEYRING_PATH" ) ]] \
    || die "Refusing to overwrite unsafe keyring path: $KEYRING_PATH"
  [[ ! -e "$SOURCE_FILE" || ( -f "$SOURCE_FILE" && ! -L "$SOURCE_FILE" ) ]] \
    || die "Refusing to overwrite unsafe APT source path: $SOURCE_FILE"

  sudo -- install -d -m 0755 /usr/share/keyrings /etc/apt/sources.list.d
  sudo -- install -m 0644 -- "$new_key" "$PENDING_KEY"
  sudo -- install -m 0644 -- "$new_source" "$PENDING_SOURCE"

  [[ ! -e "$KEYRING_PATH" ]] || HAD_KEY='true'
  [[ ! -e "$SOURCE_FILE" ]] || HAD_SOURCE='true'
  REPOSITORY_TRANSACTION_ACTIVE='true'
  if [[ "$HAD_KEY" == 'true' ]]; then
    sudo -- mv -- "$KEYRING_PATH" "$BACKUP_KEY"
  fi
  if [[ "$HAD_SOURCE" == 'true' ]]; then
    sudo -- mv -- "$SOURCE_FILE" "$BACKUP_SOURCE"
  fi
  NEW_KEY_MAY_EXIST='true'
  sudo -- mv -- "$PENDING_KEY" "$KEYRING_PATH"
  NEW_SOURCE_MAY_EXIST='true'
  sudo -- mv -- "$PENDING_SOURCE" "$SOURCE_FILE"

  validate_repository_configuration \
    || die 'The activated Google Cloud APT repository did not pass verification'
}

commit_repository() {
  REPOSITORY_TRANSACTION_ACTIVE='false'
  [[ ! -e "$BACKUP_KEY" && ! -L "$BACKUP_KEY" ]] \
    || sudo -- rm -f -- "$BACKUP_KEY" \
    || warn "Could not remove old keyring backup: $BACKUP_KEY"
  [[ ! -e "$BACKUP_SOURCE" && ! -L "$BACKUP_SOURCE" ]] \
    || sudo -- rm -f -- "$BACKUP_SOURCE" \
    || warn "Could not remove old source-file backup: $BACKUP_SOURCE"
}

package_has_candidate() {
  local package="$1"
  local metadata

  metadata="$(apt-cache show --no-all-versions "$package" 2>/dev/null)" \
    || return 1
  grep -Fxq "Package: $package" <<< "$metadata"
}

install_packages() {
  local architecture armored_key binary_key source_copy package rc key_size
  local -a unavailable=()

  if check_installation && [[ "${MINT_JELLY_FORCE_UPDATE:-false}" != 'true' ]]; then
    log "$INSTALLER_NAME and its selected options are already installed; skipping."
    return 0
  else
    rc=$?
    ((rc == 1)) || return "$rc"
  fi
  ((EUID != 0)) || die 'Run this installer as the desktop user, not as root'

  require_command apt-cache
  require_command apt-get
  require_command curl
  require_command dpkg
  require_command dpkg-query
  require_command gpg
  require_command grep
  require_command install
  require_command mktemp
  require_command mv
  require_command stat
  require_command sudo

  architecture="$(dpkg --print-architecture)"
  [[ "$architecture" == 'amd64' ]] \
    || die "$INSTALLER_NAME supports amd64 on Linux Mint; detected $architecture"

  umask 077
  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mint-jelly-google-cloud-cli.XXXXXXXX")"
  armored_key="$TEMP_DIR/google-cloud.asc"
  binary_key="$TEMP_DIR/cloud.google.gpg"
  source_copy="$TEMP_DIR/google-cloud-sdk.list"

  log 'Downloading the current Google Cloud APT public key...'
  curl --fail --show-error --silent --location \
    --retry 3 --retry-delay 2 \
    --max-filesize "$MAX_KEY_BYTES" \
    --proto '=https' --proto-redir '=https' \
    --output "$armored_key" "$KEY_URL"
  key_size="$(stat -c '%s' -- "$armored_key")"
  [[ "$key_size" =~ ^[0-9]+$ ]] \
    && ((key_size > 0 && key_size <= MAX_KEY_BYTES)) \
    || die 'Downloaded Google Cloud public key has an invalid size'
  gpg --batch --yes --dearmor --output "$binary_key" "$armored_key" \
    || die 'Could not convert the Google Cloud public key to an APT keyring'
  validate_key_file "$binary_key" \
    || die 'Downloaded Google Cloud public key is invalid or has an unexpected signer identity'
  chmod 0644 -- "$binary_key"
  printf '%s\n' "$SOURCE_LINE" > "$source_copy"
  chmod 0644 -- "$source_copy"

  log 'Installing the Google Cloud keyring and signed APT source...'
  activate_repository "$binary_key" "$source_copy"

  log 'Refreshing APT package indexes for the Google Cloud repository...'
  sudo -- env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none \
    apt-get -o Dpkg::Use-Pty=0 update

  for package in "${INSTALL_PACKAGES[@]}"; do
    package_has_candidate "$package" || unavailable+=("$package")
  done
  ((${#unavailable[@]} == 0)) \
    || die "Selected Google Cloud packages are unavailable from the configured repository: ${unavailable[*]}"

  log "Installing Google Cloud packages: ${INSTALL_PACKAGES[*]}"
  sudo -- env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none \
    apt-get -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confold \
      install --yes "${INSTALL_PACKAGES[@]}"
  verify_installation
  commit_repository
}

uninstall_packages() {
  local package
  local -a installed=()
  load_selected_options
  require_command sudo
  for package in "${INSTALL_PACKAGES[@]}"; do
    package_is_installed "$package" && installed+=("$package")
  done
  if (( ${#installed[@]} )); then
    if [[ "${MINT_JELLY_PURGE:-false}" == 'true' ]]; then
      sudo -- apt-get purge --yes "${installed[@]}"
    else
      sudo -- apt-get remove --yes "${installed[@]}"
    fi
  fi
  sudo -- rm -f -- "$SOURCE_FILE" "$KEYRING_PATH"
  [[ "${MINT_JELLY_PURGE:-false}" != 'true' ]] || rm -rf -- "$HOME/.config/gcloud"
}

usage() {
  printf 'Usage: %s {check|install|update|uninstall|verify|option-check OPTION}\n' "${0##*/}" >&2
}

main() {
  trap cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  case "${1-}" in
    check)
      (($# == 1)) || { usage; return 64; }
      check_installation
      ;;
    install)
      (($# == 1)) || { usage; return 64; }
      install_packages
      ;;
    update)
      (($# == 1)) || { usage; return 64; }
      MINT_JELLY_FORCE_UPDATE=true install_packages
      ;;
    uninstall)
      (($# == 1)) || { usage; return 64; }
      uninstall_packages
      ;;
    verify)
      (($# == 1)) || { usage; return 64; }
      verify_installation
      ;;
    option-check)
      (($# == 2)) || { usage; return 64; }
      option_is_allowed "$2" || die "Unsupported $INSTALLER_NAME option: $2"
      package_is_installed "$2"
      ;;
    *)
      usage
      return 64
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
