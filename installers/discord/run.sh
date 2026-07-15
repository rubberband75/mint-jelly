#!/usr/bin/env bash

set -Eeuo pipefail

readonly INSTALLER_NAME="Discord"
readonly PACKAGE_NAME="discord"
readonly PACKAGE_URL="https://discord.com/api/download/stable?platform=linux&format=deb"
readonly EXPECTED_EXECUTABLE="/usr/bin/discord"
readonly MAX_DOWNLOAD_BYTES="1073741824"

TEMP_DIR=""

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

cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
}

trap cleanup EXIT

check_installation() {
  local rc status

  if ! command -v dpkg-query >/dev/null 2>&1; then
    printf 'Error: Required command not found: dpkg-query\n' >&2
    return 2
  fi
  if status="$(dpkg-query -W -f='${db:Status-Abbrev}' "$PACKAGE_NAME" 2>/dev/null)"; then
    :
  else
    rc=$?
    ((rc == 1)) && return 1
    return "$rc"
  fi

  [[ "$status" == "ii " ]]
}

verify_installation() {
  local architecture file integrity_output package_files rc version
  local executable_is_owned='false'

  if check_installation; then
    :
  else
    rc=$?
    if ((rc == 1)); then
      printf '%s is not installed.\n' "$INSTALLER_NAME" >&2
    fi
    return "$rc"
  fi

  if ! command -v dpkg >/dev/null 2>&1; then
    printf 'Error: Required command not found: dpkg\n' >&2
    return 2
  fi

  version="$(dpkg-query -W -f='${Version}' "$PACKAGE_NAME" 2>/dev/null || true)"
  architecture="$(dpkg-query -W -f='${Architecture}' "$PACKAGE_NAME" 2>/dev/null || true)"
  if [[ -z "$version" ]] || ! dpkg --validate-version "$version" >/dev/null 2>&1; then
    printf 'Error: Installed %s package has an invalid version.\n' "$INSTALLER_NAME" >&2
    return 2
  fi
  if [[ "$architecture" != "amd64" ]]; then
    printf 'Error: Installed %s package has unexpected architecture: %s\n' \
      "$INSTALLER_NAME" "${architecture:-unknown}" >&2
    return 2
  fi

  [[ -x "$EXPECTED_EXECUTABLE" ]] || {
    printf 'Error: Installed %s package is missing executable: %s\n' \
      "$INSTALLER_NAME" "$EXPECTED_EXECUTABLE" >&2
    return 2
  }
  if ! package_files="$(dpkg-query -L "$PACKAGE_NAME" 2>/dev/null)"; then
    printf 'Error: Could not read the installed %s package file list.\n' "$INSTALLER_NAME" >&2
    return 2
  fi
  while IFS= read -r file; do
    if [[ "$file" == "$EXPECTED_EXECUTABLE" ]]; then
      executable_is_owned='true'
      break
    fi
  done <<< "$package_files"
  [[ "$executable_is_owned" == 'true' ]] || {
    printf 'Error: %s is not owned by the installed %s package.\n' \
      "$EXPECTED_EXECUTABLE" "$INSTALLER_NAME" >&2
    return 2
  }
  if integrity_output="$(dpkg --verify "$PACKAGE_NAME" 2>&1)"; then
    :
  else
    rc=$?
    printf 'Error: Installed %s package failed dpkg integrity verification (status %d): %s\n' \
      "$INSTALLER_NAME" "$rc" "${integrity_output:-no diagnostic output}" >&2
    return 2
  fi
  if [[ -n "$integrity_output" ]]; then
    printf 'Error: Installed %s package reported integrity differences: %s\n' \
      "$INSTALLER_NAME" "$integrity_output" >&2
    return 2
  fi

  printf '%s is installed (version %s, %s).\n' "$INSTALLER_NAME" "$version" "$architecture"
}

validate_deb() {
  local architecture package version
  local deb_file="$1"

  [[ -f "$deb_file" && ! -L "$deb_file" && -s "$deb_file" ]] || die "Downloaded package is not a regular, non-empty file"
  dpkg-deb --info "$deb_file" >/dev/null 2>&1 || die "Downloaded file is not a valid Debian package"

  package="$(dpkg-deb -f "$deb_file" Package 2>/dev/null || true)"
  version="$(dpkg-deb -f "$deb_file" Version 2>/dev/null || true)"
  architecture="$(dpkg-deb -f "$deb_file" Architecture 2>/dev/null || true)"

  [[ "$package" == "$PACKAGE_NAME" ]] || die "Unexpected Debian package name: ${package:-unknown}"
  [[ "$architecture" == "amd64" ]] || die "Unexpected Debian package architecture: ${architecture:-unknown}"
  [[ -n "$version" ]] && dpkg --validate-version "$version" >/dev/null 2>&1 \
    || die "Downloaded Debian package has an invalid version"

  printf '%s\n' "$version"
}

install_package() {
  local architecture deb_file rc version

  if check_installation; then
    log "$INSTALLER_NAME is already installed; skipping."
    return 0
  else
    rc=$?
    ((rc == 1)) || return "$rc"
  fi

  ((EUID != 0)) || die "Run this installer as the desktop user, not as root"

  require_command apt-get
  require_command curl
  require_command dpkg
  require_command dpkg-deb
  require_command mktemp
  require_command sudo

  architecture="$(dpkg --print-architecture)"
  [[ "$architecture" == "amd64" ]] || die "$INSTALLER_NAME supports amd64 on Linux Mint; detected $architecture"

  umask 077
  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mint-jelly-discord.XXXXXXXX")"
  deb_file="$TEMP_DIR/discord.deb"

  log "Downloading the official stable Discord package..."
  curl \
    --fail --show-error --silent --location \
    --retry 3 --retry-delay 2 \
    --max-filesize "$MAX_DOWNLOAD_BYTES" \
    --proto '=https' --proto-redir '=https' \
    --output "$deb_file" \
    "$PACKAGE_URL"

  warn "Discord does not publish a checksum at this download endpoint; authenticity is limited to HTTPS and Debian metadata validation."
  version="$(validate_deb "$deb_file")"
  log "Validated Discord Debian package version $version."

  chmod 0644 "$deb_file"
  log "Installing $INSTALLER_NAME..."
  chmod 0711 "$TEMP_DIR"
  sudo -- env \
    DEBIAN_FRONTEND=noninteractive \
    APT_LISTCHANGES_FRONTEND=none \
    apt-get -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confold \
      install --yes "$deb_file"
  verify_installation
}

usage() {
  printf 'Usage: %s {check|install|verify}\n' "${0##*/}" >&2
}

main() {
  (($# == 1)) || {
    usage
    return 64
  }

  case "$1" in
    check) check_installation ;;
    install) install_package ;;
    verify) verify_installation ;;
    *)
      usage
      return 64
      ;;
  esac
}

main "$@"
