#!/usr/bin/env bash

set -Eeuo pipefail

readonly INSTALLER_NAME="Slack Desktop"
readonly PACKAGE_NAME="slack-desktop"
readonly DOWNLOAD_PAGE="https://slack.com/downloads/instructions/linux?build=deb&nojsmode=1"
readonly EXPECTED_EXECUTABLE="/usr/bin/slack"
readonly CANONICAL_EXECUTABLE="/usr/lib/slack/slack"
readonly MAX_METADATA_BYTES="10485760"
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
  local architecture file integrity_output link_target package_files rc version
  local executable_is_owned='false'
  local canonical_is_owned='false'

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

  command -v readlink >/dev/null 2>&1 || {
    printf 'Error: Required command not found: readlink\n' >&2
    return 2
  }
  [[ -f "$CANONICAL_EXECUTABLE" && ! -L "$CANONICAL_EXECUTABLE" \
    && -x "$CANONICAL_EXECUTABLE" ]] || {
    printf 'Error: Installed %s package is missing canonical executable: %s\n' \
      "$INSTALLER_NAME" "$CANONICAL_EXECUTABLE" >&2
    return 2
  }
  [[ -L "$EXPECTED_EXECUTABLE" && -x "$EXPECTED_EXECUTABLE" ]] || {
    printf 'Error: Installed %s package is missing command symlink: %s\n' \
      "$INSTALLER_NAME" "$EXPECTED_EXECUTABLE" >&2
    return 2
  }
  link_target="$(readlink -- "$EXPECTED_EXECUTABLE" 2>/dev/null || true)"
  [[ "$link_target" == '../lib/slack/slack' \
    && "$EXPECTED_EXECUTABLE" -ef "$CANONICAL_EXECUTABLE" ]] || {
    printf 'Error: %s does not safely target %s.\n' \
      "$EXPECTED_EXECUTABLE" "$CANONICAL_EXECUTABLE" >&2
    return 2
  }
  if ! package_files="$(dpkg-query -L "$PACKAGE_NAME" 2>/dev/null)"; then
    printf 'Error: Could not read the installed %s package file list.\n' "$INSTALLER_NAME" >&2
    return 2
  fi
  while IFS= read -r file; do
    if [[ "$file" == "$EXPECTED_EXECUTABLE" ]]; then
      executable_is_owned='true'
    elif [[ "$file" == "$CANONICAL_EXECUTABLE" ]]; then
      canonical_is_owned='true'
    fi
  done <<< "$package_files"
  [[ "$executable_is_owned" == 'true' ]] || {
    printf 'Error: %s is not owned by the installed %s package.\n' \
      "$EXPECTED_EXECUTABLE" "$INSTALLER_NAME" >&2
    return 2
  }
  [[ "$canonical_is_owned" == 'true' ]] || {
    printf 'Error: %s is not owned by the installed %s package.\n' \
      "$CANONICAL_EXECUTABLE" "$INSTALLER_NAME" >&2
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

uninstall_package() {
  local rc
  require_command sudo
  if check_installation; then
    if [[ "${MINT_JELLY_PURGE:-false}" == 'true' ]]; then
      sudo -- apt-get purge --yes "$PACKAGE_NAME"
    else
      sudo -- apt-get remove --yes "$PACKAGE_NAME"
    fi
  else
    rc=$?; ((rc == 1)) || return "$rc"
  fi
  [[ "${MINT_JELLY_PURGE:-false}" != 'true' ]] || rm -rf -- "$HOME/.config/Slack"
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
  local architecture deb_file page_file package_url rc version

  if check_installation && [[ "${MINT_JELLY_FORCE_UPDATE:-false}" != 'true' ]]; then
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
  require_command python3
  require_command sudo

  architecture="$(dpkg --print-architecture)"
  [[ "$architecture" == "amd64" ]] || die "$INSTALLER_NAME supports amd64 on Linux Mint; detected $architecture"

  umask 077
  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mint-jelly-slack.XXXXXXXX")"
  page_file="$TEMP_DIR/download.html"
  deb_file="$TEMP_DIR/slack-desktop.deb"

  log "Resolving the latest official Slack Debian package..."
  curl \
    --fail --show-error --silent --location \
    --retry 3 --retry-delay 2 \
    --max-filesize "$MAX_METADATA_BYTES" \
    --proto '=https' --proto-redir '=https' \
    --output "$page_file" \
    "$DOWNLOAD_PAGE"

  if ! package_url="$(python3 - "$page_file" <<'PY'
import html
import re
import sys

with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as stream:
    page = html.unescape(stream.read())

pattern = re.compile(
    r"https://downloads[.]slack-edge[.]com/desktop-releases/linux/x64/"
    r"([0-9]+(?:[.][0-9]+)+)/slack-desktop-\1-amd64[.]deb"
)
matches = [(tuple(int(part) for part in version.split(".")), url) for version, url in (
    (match.group(1), match.group(0)) for match in pattern.finditer(page)
)]
if not matches:
    raise SystemExit("official page contains no recognized amd64 Debian package URL")

print(max(matches)[1])
PY
  )"; then
    die "Could not parse Slack's Debian package URL from its official download page"
  fi

  [[ "$package_url" =~ ^https://downloads\.slack-edge\.com/desktop-releases/linux/x64/[0-9]+(\.[0-9]+)+/slack-desktop-[0-9]+(\.[0-9]+)+-amd64\.deb$ ]] \
    || die "Slack returned an unexpected package URL"

  log "Downloading the official Slack Desktop package..."
  curl \
    --fail --show-error --silent --location \
    --retry 3 --retry-delay 2 \
    --max-filesize "$MAX_DOWNLOAD_BYTES" \
    --proto '=https' --proto-redir '=https' \
    --output "$deb_file" \
    "$package_url"

  warn "Slack does not publish a checksum with this download; authenticity is limited to HTTPS and Debian metadata validation."
  version="$(validate_deb "$deb_file")"
  log "Validated Slack Desktop Debian package version $version."

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
  printf 'Usage: %s {check|install|update|uninstall|verify}\n' "${0##*/}" >&2
}

main() {
  (($# == 1)) || {
    usage
    return 64
  }

  case "$1" in
    check) check_installation ;;
    install) install_package ;;
    update) MINT_JELLY_FORCE_UPDATE=true install_package ;;
    uninstall) uninstall_package ;;
    verify) verify_installation ;;
    *)
      usage
      return 64
      ;;
  esac
}

main "$@"
