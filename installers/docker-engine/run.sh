#!/usr/bin/env bash

set -Eeuo pipefail

readonly INSTALLER_NAME='Docker Engine'
readonly KEY_URL='https://download.docker.com/linux/ubuntu/gpg'
readonly KEYRING_PATH='/etc/apt/keyrings/docker.asc'
readonly SOURCE_FILE='/etc/apt/sources.list.d/docker.sources'
readonly DOCKER_KEY_FINGERPRINT='9DC858229FC7DD38854AE2D88D81803C0EBFCD88'
readonly MAX_KEY_BYTES='1048576'
readonly -a ENGINE_PACKAGES=(
  docker-ce
  docker-ce-cli
  containerd.io
  docker-buildx-plugin
  docker-compose-plugin
)
readonly -a UNINSTALL_PACKAGES=(
  docker-ce
  docker-ce-cli
  containerd.io
  docker-buildx-plugin
  docker-compose-plugin
  docker-ce-rootless-extras
)
readonly -a CONFLICTING_PACKAGES=(
  docker.io
  docker-compose
  docker-compose-v2
  docker-doc
  podman-docker
  containerd
  runc
)

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

read_os_release_value() {
  local wanted="$1" file="${2:-/etc/os-release}"
  local key value

  [[ -f "$file" && -r "$file" ]] || return 1
  while IFS='=' read -r key value; do
    [[ "$key" == "$wanted" ]] || continue
    if [[ "$value" == \"*\" && "$value" == *\" ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
      value="${value:1:${#value}-2}"
    fi
    printf '%s\n' "$value"
    return 0
  done < "$file"
  return 1
}

ubuntu_codename() {
  local codename

  codename="$(read_os_release_value UBUNTU_CODENAME 2>/dev/null || true)"
  [[ -n "$codename" ]] \
    || codename="$(read_os_release_value VERSION_CODENAME 2>/dev/null || true)"
  [[ "$codename" =~ ^[a-z][a-z0-9-]*$ ]] \
    || die 'Could not determine a safe Ubuntu base codename from /etc/os-release'
  printf '%s\n' "$codename"
}

architecture_is_supported() {
  case "$1" in
    amd64|arm64|armhf|s390x|ppc64el) return 0 ;;
    *) return 1 ;;
  esac
}

expected_source_content() {
  local architecture="$1" codename="$2"

  printf '%s\n' \
    'Types: deb' \
    'URIs: https://download.docker.com/linux/ubuntu' \
    "Suites: $codename" \
    'Components: stable' \
    "Architectures: $architecture" \
    "Signed-By: $KEYRING_PATH"
}

validate_key_file() {
  local key_file="$1"
  local key_data gnupg_home status

  [[ -f "$key_file" && ! -L "$key_file" && -s "$key_file" ]] || return 1
  gnupg_home="$(mktemp -d "${TMPDIR:-/tmp}/mint-jelly-docker-gpg.XXXXXXXX")" \
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
  grep -Fxq "fpr:::::::::$DOCKER_KEY_FINGERPRINT:" <<< "$key_data" \
    || return 1
  grep -Fq ':Docker Release (CE deb) <docker@docker.com>:' <<< "$key_data"
}

source_file_is_exact() {
  local architecture codename actual expected

  [[ -f "$SOURCE_FILE" && ! -L "$SOURCE_FILE" ]] || return 1
  architecture="$(dpkg --print-architecture)" || return 1
  codename="$(ubuntu_codename)" || return 1
  expected="$(expected_source_content "$architecture" "$codename")"
  actual="$(< "$SOURCE_FILE")"
  [[ "$actual" == "$expected" ]]
}

no_duplicate_docker_sources() {
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
    if grep -Fq 'download.docker.com/linux/ubuntu' "$file" 2>/dev/null; then
      printf 'Error: Duplicate Docker APT repository configuration found: %s\n' \
        "$file" >&2
      return 1
    fi
  done
}

validate_repository_configuration() {
  local missing='false'

  no_duplicate_docker_sources || return 2
  if [[ ! -e "$SOURCE_FILE" && ! -L "$SOURCE_FILE" ]]; then
    missing='true'
  elif ! source_file_is_exact \
    || ! path_permissions_are_safe "$SOURCE_FILE" \
    || ! path_is_root_owned "$SOURCE_FILE"; then
    printf 'Error: Docker APT source is unexpected or unsafe: %s\n' \
      "$SOURCE_FILE" >&2
    return 2
  fi

  if [[ ! -e "$KEYRING_PATH" && ! -L "$KEYRING_PATH" ]]; then
    missing='true'
  elif [[ ! -f "$KEYRING_PATH" || -L "$KEYRING_PATH" ]] \
    || ! path_permissions_are_safe "$KEYRING_PATH" \
    || ! path_is_root_owned "$KEYRING_PATH" \
    || ! validate_key_file "$KEYRING_PATH"; then
    printf 'Error: Docker APT keyring is unexpected or unsafe: %s\n' \
      "$KEYRING_PATH" >&2
    return 2
  fi

  [[ "$missing" == 'false' ]] || return 1
}

target_user() {
  local user

  user="$(id -un "$UID" 2>/dev/null || true)"
  [[ -n "$user" && "$user" != 'root' && "$user" != *:* && "$user" != *$'\n'* ]] \
    || die 'Run this installer as the desktop user, not as root'
  printf '%s\n' "$user"
}

docker_group_has_user() {
  local user="$1" entry group_gid primary_gid members member
  local -a member_list=()

  entry="$(getent group docker 2>/dev/null)" || return 1
  IFS=':' read -r _ _ group_gid members <<< "$entry"
  primary_gid="$(id -g "$user" 2>/dev/null)" || return 1
  [[ "$primary_gid" != "$group_gid" ]] || return 0
  IFS=',' read -r -a member_list <<< "$members"
  for member in "${member_list[@]}"; do
    [[ "$member" == "$user" ]] && return 0
  done
  return 1
}

service_is_ready() {
  systemctl is-active --quiet docker.service \
    && systemctl is-enabled --quiet docker.service
}

check_installation() {
  local package status user
  local missing='false'

  for package in dpkg-query gpg grep id getent mktemp stat systemctl; do
    command -v "$package" >/dev/null 2>&1 || {
      printf 'Error: Required command not found: %s\n' "$package" >&2
      return 2
    }
  done
  if validate_repository_configuration; then
    :
  else
    status=$?
    ((status == 1)) || return "$status"
    missing='true'
  fi
  for package in "${ENGINE_PACKAGES[@]}"; do
    if package_is_installed "$package"; then
      :
    else
      status=$?
      ((status == 1)) || return "$status"
      missing='true'
    fi
  done
  user="$(target_user)"
  docker_group_has_user "$user" || missing='true'
  service_is_ready || missing='true'
  [[ "$missing" == 'false' ]]
}

verify_package() {
  local package="$1" architecture integrity_output version

  package_is_installed "$package" || return $?
  version="$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null || true)"
  architecture="$(dpkg-query -W -f='${Architecture}' "$package" 2>/dev/null || true)"
  [[ -n "$version" ]] && dpkg --validate-version "$version" >/dev/null 2>&1 \
    || return 1
  [[ "$architecture" == "$(dpkg --print-architecture)" || "$architecture" == 'all' ]] \
    || return 1
  if integrity_output="$(dpkg --verify "$package" 2>&1)"; then
    [[ -z "$integrity_output" ]]
  else
    return 1
  fi
}

verify_installation() {
  local package package_files rc user version

  if check_installation; then
    :
  else
    rc=$?
    ((rc != 1)) || printf '%s is not fully installed or configured.\n' \
      "$INSTALLER_NAME" >&2
    return "$rc"
  fi
  require_command docker
  require_command dpkg
  for package in "${ENGINE_PACKAGES[@]}"; do
    verify_package "$package" || {
      printf 'Error: Installed package failed verification: %s\n' "$package" >&2
      return 2
    }
  done
  [[ "$(command -v docker)" == '/usr/bin/docker' ]] || {
    printf 'Error: Docker CLI resolves outside the installed system package.\n' >&2
    return 2
  }
  package_files="$(dpkg-query -L docker-ce-cli 2>/dev/null)" || return 2
  grep -Fxq '/usr/bin/docker' <<< "$package_files" || {
    printf 'Error: /usr/bin/docker is not owned by docker-ce-cli.\n' >&2
    return 2
  }
  docker compose version >/dev/null 2>&1 || {
    printf 'Error: Docker Compose plugin failed verification.\n' >&2
    return 2
  }
  docker buildx version >/dev/null 2>&1 || {
    printf 'Error: Docker Buildx plugin failed verification.\n' >&2
    return 2
  }
  user="$(target_user)"
  version="$(dpkg-query -W -f='${Version}' docker-ce)"
  printf '%s is installed (version %s); user %s has docker-group access.\n' \
    "$INSTALLER_NAME" "$version" "$user"
}

rollback_repository_transaction() {
  local rollback_ok='true'

  [[ "$REPOSITORY_TRANSACTION_ACTIVE" == 'true' ]] || return 0
  warn 'Rolling back the interrupted Docker APT repository update.'
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
  local new_key="$1" new_source="$2"

  PENDING_KEY="/etc/apt/keyrings/.mint-jelly-docker-new-$$"
  PENDING_SOURCE="/etc/apt/sources.list.d/.mint-jelly-docker-new-$$"
  BACKUP_KEY="/etc/apt/keyrings/.mint-jelly-docker-old-$$"
  BACKUP_SOURCE="/etc/apt/sources.list.d/.mint-jelly-docker-old-$$"
  if [[ -e "$PENDING_KEY" || -L "$PENDING_KEY" \
    || -e "$PENDING_SOURCE" || -L "$PENDING_SOURCE" \
    || -e "$BACKUP_KEY" || -L "$BACKUP_KEY" \
    || -e "$BACKUP_SOURCE" || -L "$BACKUP_SOURCE" ]]; then
    die 'Refusing to overwrite an existing Docker repository transaction path'
  fi
  [[ ! -e "$KEYRING_PATH" || ( -f "$KEYRING_PATH" && ! -L "$KEYRING_PATH" ) ]] \
    || die "Refusing to overwrite unsafe keyring path: $KEYRING_PATH"
  [[ ! -e "$SOURCE_FILE" || ( -f "$SOURCE_FILE" && ! -L "$SOURCE_FILE" ) ]] \
    || die "Refusing to overwrite unsafe APT source path: $SOURCE_FILE"

  REPOSITORY_TRANSACTION_ACTIVE='true'
  sudo -- install -d -m 0755 /etc/apt/keyrings /etc/apt/sources.list.d
  sudo -- install -m 0644 -- "$new_key" "$PENDING_KEY"
  sudo -- install -m 0644 -- "$new_source" "$PENDING_SOURCE"
  [[ ! -e "$KEYRING_PATH" ]] || HAD_KEY='true'
  [[ ! -e "$SOURCE_FILE" ]] || HAD_SOURCE='true'
  [[ "$HAD_KEY" != 'true' ]] || sudo -- mv -- "$KEYRING_PATH" "$BACKUP_KEY"
  [[ "$HAD_SOURCE" != 'true' ]] || sudo -- mv -- "$SOURCE_FILE" "$BACKUP_SOURCE"
  NEW_KEY_MAY_EXIST='true'
  sudo -- mv -- "$PENDING_KEY" "$KEYRING_PATH"
  NEW_SOURCE_MAY_EXIST='true'
  sudo -- mv -- "$PENDING_SOURCE" "$SOURCE_FILE"
  validate_repository_configuration \
    || die 'The activated Docker APT repository did not pass verification'
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
  local package="$1" metadata

  metadata="$(apt-cache show --no-all-versions "$package" 2>/dev/null)" \
    || return 1
  grep -Fxq "Package: $package" <<< "$metadata"
}

remove_conflicting_packages() {
  local package
  local -a installed=()

  for package in "${CONFLICTING_PACKAGES[@]}"; do
    package_is_installed "$package" && installed+=("$package")
  done
  ((${#installed[@]} == 0)) && return 0
  log "Removing packages that conflict with Docker Engine: ${installed[*]}"
  sudo -- env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none \
    apt-get -o Dpkg::Use-Pty=0 remove --yes "${installed[@]}"
}

configure_non_root_access() {
  local user uid gid

  user="$(target_user)"
  uid="$(id -u "$user")"
  gid="$(id -g "$user")"
  getent group docker >/dev/null 2>&1 || sudo -- groupadd docker
  if ! docker_group_has_user "$user"; then
    log "Adding $user to the docker group (this grants root-level privileges)..."
    sudo -- usermod -aG docker "$user"
  fi
  docker_group_has_user "$user" \
    || die "Could not add $user to the docker group"

  if [[ -e "$HOME/.docker" || -L "$HOME/.docker" ]]; then
    [[ -d "$HOME/.docker" && ! -L "$HOME/.docker" ]] \
      || die "Refusing to modify unexpected Docker configuration path: $HOME/.docker"
    sudo -- chown -R -- "$uid:$gid" "$HOME/.docker"
    sudo -- chmod -R -- u+rwX,g+rwX "$HOME/.docker"
  fi
}

install_engine() {
  local architecture codename key_file key_size package rc source_copy
  local -a unavailable=()

  ((EUID != 0)) || die 'Run this installer as the desktop user, not as root'
  require_command apt-get
  require_command dpkg
  require_command dpkg-query
  require_command sudo

  log 'Refreshing APT indexes and installing repository prerequisites...'
  sudo -- env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none \
    apt-get -o Dpkg::Use-Pty=0 update
  sudo -- env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none \
    apt-get -o Dpkg::Use-Pty=0 install --yes ca-certificates curl gnupg
  for package in apt-cache curl getent gpg grep id install mktemp stat systemctl; do
    require_command "$package"
  done

  if check_installation && [[ "${MINT_JELLY_FORCE_UPDATE:-false}" != 'true' ]]; then
    log "$INSTALLER_NAME is already installed and configured; skipping."
    return 0
  else
    rc=$?
    ((rc == 1)) || return "$rc"
  fi

  architecture="$(dpkg --print-architecture)"
  architecture_is_supported "$architecture" \
    || die "$INSTALLER_NAME does not support architecture: $architecture"
  codename="$(ubuntu_codename)"
  remove_conflicting_packages

  umask 077
  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mint-jelly-docker-engine.XXXXXXXX")"
  key_file="$TEMP_DIR/docker.asc"
  source_copy="$TEMP_DIR/docker.sources"
  log "Downloading Docker's current APT signing key..."
  curl --fail --show-error --silent --location \
    --retry 3 --retry-delay 2 \
    --max-filesize "$MAX_KEY_BYTES" \
    --proto '=https' --proto-redir '=https' \
    --output "$key_file" "$KEY_URL"
  key_size="$(stat -c '%s' -- "$key_file")"
  [[ "$key_size" =~ ^[0-9]+$ ]] \
    && ((key_size > 0 && key_size <= MAX_KEY_BYTES)) \
    || die 'Downloaded Docker public key has an invalid size'
  validate_key_file "$key_file" \
    || die 'Downloaded Docker public key has an unexpected fingerprint or signer identity'
  chmod 0644 -- "$key_file"
  expected_source_content "$architecture" "$codename" > "$source_copy"
  chmod 0644 -- "$source_copy"

  log "Installing Docker's signed APT repository..."
  activate_repository "$key_file" "$source_copy"
  sudo -- env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none \
    apt-get -o Dpkg::Use-Pty=0 update
  for package in "${ENGINE_PACKAGES[@]}"; do
    package_has_candidate "$package" || unavailable+=("$package")
  done
  ((${#unavailable[@]} == 0)) \
    || die "Docker packages are unavailable for Ubuntu $codename/$architecture: ${unavailable[*]}"

  log "Installing Docker packages: ${ENGINE_PACKAGES[*]}"
  sudo -- env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none \
    apt-get -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confold \
      install --yes "${ENGINE_PACKAGES[@]}"
  sudo -- systemctl enable --now containerd.service docker.service
  configure_non_root_access
  verify_installation
  commit_repository
  log 'Log out and back in before running docker without sudo (or run: newgrp docker).'
}

remove_group_membership() {
  local user

  user="$(target_user)"
  docker_group_has_user "$user" || return 0
  if [[ "$(id -g "$user")" == "$(getent group docker | cut -d: -f3)" ]]; then
    warn "The docker group is $user's primary group; it was not changed."
    return 0
  fi
  sudo -- gpasswd -d "$user" docker >/dev/null
}

purge_configuration() {
  if [[ -e "$HOME/.docker" || -L "$HOME/.docker" ]]; then
    [[ ! -L "$HOME/.docker" ]] \
      || die "Refusing to purge symlinked Docker configuration: $HOME/.docker"
    rm -rf -- "$HOME/.docker" 2>/dev/null \
      || sudo -- rm -rf --one-file-system -- "$HOME/.docker"
  fi
  sudo -- rm -rf --one-file-system -- \
    /etc/docker /etc/systemd/system/docker.service.d
  sudo -- systemctl daemon-reload
}

uninstall_engine() {
  local package
  local -a installed=()

  ((EUID != 0)) || die 'Run this installer as the desktop user, not as root'
  require_command dpkg-query
  require_command getent
  require_command apt-get
  require_command cut
  require_command gpasswd
  require_command id
  require_command sudo
  require_command systemctl
  for package in "${UNINSTALL_PACKAGES[@]}"; do
    package_is_installed "$package" && installed+=("$package")
  done
  if ((${#installed[@]})); then
    if [[ "${MINT_JELLY_PURGE:-false}" == 'true' ]]; then
      sudo -- env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none \
        apt-get -o Dpkg::Use-Pty=0 purge --yes "${installed[@]}"
    else
      sudo -- env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none \
        apt-get -o Dpkg::Use-Pty=0 remove --yes "${installed[@]}"
    fi
  fi
  sudo -- rm -f -- "$SOURCE_FILE" "$KEYRING_PATH"
  remove_group_membership
  if [[ "${MINT_JELLY_PURGE:-false}" == 'true' ]]; then
    purge_configuration
  fi
  log 'Docker images, containers, volumes, and containerd data were preserved.'
  log 'To destroy them explicitly, remove /var/lib/docker and /var/lib/containerd yourself.'
}

usage() {
  printf 'Usage: %s {check|install|update|uninstall|verify}\n' "${0##*/}" >&2
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
      install_engine
      ;;
    update)
      (($# == 1)) || { usage; return 64; }
      MINT_JELLY_FORCE_UPDATE=true install_engine
      ;;
    uninstall)
      (($# == 1)) || { usage; return 64; }
      uninstall_engine
      ;;
    verify)
      (($# == 1)) || { usage; return 64; }
      verify_installation
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
