#!/usr/bin/env bash

set -Eeuo pipefail

readonly INSTALLER_NAME="Heroic Games Launcher"
readonly PACKAGE_NAME="heroic"
readonly RELEASE_API="https://api.github.com/repos/Heroic-Games-Launcher/HeroicGamesLauncher/releases/latest"
readonly EXPECTED_EXECUTABLE="/opt/Heroic/heroic"
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
  local architecture asset_digest asset_name asset_url downloaded_digest rc version
  local -a release_fields
  local deb_file release_file release_metadata

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
  require_command python3
  require_command sha256sum
  require_command sudo

  architecture="$(dpkg --print-architecture)"
  [[ "$architecture" == "amd64" ]] || die "$INSTALLER_NAME supports amd64 on Linux Mint; detected $architecture"

  umask 077
  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mint-jelly-heroic.XXXXXXXX")"
  release_file="$TEMP_DIR/release.json"
  release_metadata="$TEMP_DIR/release-fields"
  deb_file="$TEMP_DIR/heroic.deb"

  log "Resolving the latest official Heroic release..."
  curl \
    --fail --show-error --silent --location \
    --retry 3 --retry-delay 2 \
    --max-filesize "$MAX_METADATA_BYTES" \
    --proto '=https' --proto-redir '=https' \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --user-agent 'mint-jelly-installer' \
    --output "$release_file" \
    "$RELEASE_API"

  if ! python3 - "$release_file" >"$release_metadata" <<'PY'
import json
import re
import sys

with open(sys.argv[1], "r", encoding="utf-8") as stream:
    release = json.load(stream)

pattern = re.compile(r"^Heroic-[A-Za-z0-9.+_-]+-linux-amd64[.]deb$")
matches = [asset for asset in release.get("assets", []) if pattern.fullmatch(str(asset.get("name", "")))]
if len(matches) != 1:
    raise SystemExit(f"expected exactly one amd64 Debian asset, found {len(matches)}")

asset = matches[0]
name = asset["name"]
url = str(asset.get("browser_download_url", ""))
digest = str(asset.get("digest") or "")
if digest and not re.fullmatch(r"sha256:[0-9a-fA-F]{64}", digest):
    raise SystemExit("release asset has a malformed SHA-256 digest")

print(name)
print(url)
print(digest.removeprefix("sha256:"))
PY
  then
    die "Could not parse a unique Heroic Debian asset from the GitHub release"
  fi

  mapfile -t release_fields <"$release_metadata"
  ((${#release_fields[@]} == 3)) || die "Heroic release metadata was incomplete"
  asset_name="${release_fields[0]}"
  asset_url="${release_fields[1]}"
  asset_digest="${release_fields[2]}"

  [[ "$asset_url" =~ ^https://github\.com/Heroic-Games-Launcher/HeroicGamesLauncher/releases/download/[^/]+/[^/]+$ ]] \
    || die "Heroic release returned an unexpected download URL"
  [[ "${asset_url##*/}" == "$asset_name" ]] || die "Heroic asset name does not match its download URL"

  log "Downloading $asset_name..."
  curl \
    --fail --show-error --silent --location \
    --retry 3 --retry-delay 2 \
    --max-filesize "$MAX_DOWNLOAD_BYTES" \
    --proto '=https' --proto-redir '=https' \
    --output "$deb_file" \
    "$asset_url"

  [[ -n "$asset_digest" ]] \
    || die "Heroic's release asset has no required SHA-256 digest"
  downloaded_digest="$(sha256sum "$deb_file")"
  downloaded_digest="${downloaded_digest%% *}"
  [[ "${downloaded_digest,,}" == "${asset_digest,,}" ]] || die "Heroic package SHA-256 verification failed"
  log "Verified the required upstream SHA-256 digest."

  version="$(validate_deb "$deb_file")"
  log "Validated Heroic Debian package version $version."

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
