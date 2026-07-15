#!/usr/bin/env bash

set -Eeuo pipefail

readonly INSTALLER_NAME='Visual Studio Code'
readonly PACKAGE_NAME='code'
readonly UPDATE_API='https://update.code.visualstudio.com/api/update/linux-deb-x64/stable/latest'
readonly KEYRING_PATH='/usr/share/keyrings/microsoft.gpg'
readonly SOURCE_FILE='/etc/apt/sources.list.d/vscode.sources'
readonly LEGACY_SOURCE_FILE='/etc/apt/sources.list.d/vscode.list'
readonly MICROSOFT_KEY_FINGERPRINT='BC528686B50D79E339D3721CEB3E94ADBE1229CF'
readonly EXPECTED_COMMAND='/usr/bin/code'
readonly COMMAND_TARGET='/usr/share/code/bin/code'
readonly EXPECTED_EXECUTABLE='/usr/share/code/code'
readonly MAX_METADATA_BYTES='1048576'
readonly MAX_DOWNLOAD_BYTES='1073741824'

TEMP_DIR=''

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

trim_text() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
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
  local output status

  if output="$(dpkg-query -W -f='${db:Status-Abbrev}' "$PACKAGE_NAME" 2>/dev/null)"; then
    [[ "$output" == 'ii ' ]]
    return
  else
    status=$?
  fi
  ((status == 1)) && return 1
  return "$status"
}

architecture_list_is_valid() {
  local value="$1" architecture token
  local found='false'
  local -a tokens=()

  architecture="$(dpkg --print-architecture)" || return 1
  value="${value//,/ }"
  read -r -a tokens <<< "$value"
  ((${#tokens[@]} > 0)) || return 1
  for token in "${tokens[@]}"; do
    case "$token" in
      amd64|arm64|armhf) ;;
      *) return 1 ;;
    esac
    [[ "$token" != "$architecture" ]] || found='true'
  done
  [[ "$found" == 'true' ]]
}

validate_source_file() {
  local source_file="$1" raw key value
  local -A seen=()

  [[ -f "$source_file" && ! -L "$source_file" && -r "$source_file" ]] \
    || return 1
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    raw="$(trim_text "$raw")"
    [[ -z "$raw" || "$raw" == \#* ]] && continue
    [[ "$raw" == *:* ]] || return 1
    key="$(trim_text "${raw%%:*}")"
    value="$(trim_text "${raw#*:}")"
    [[ -n "$key" && -n "$value" && -z "${seen[$key]+set}" ]] || return 1
    seen["$key"]="$value"
    case "$key" in
      Types) [[ "$value" == 'deb' ]] || return 1 ;;
      URIs) [[ "$value" == 'https://packages.microsoft.com/repos/code' ]] || return 1 ;;
      Suites) [[ "$value" == 'stable' ]] || return 1 ;;
      Components) [[ "$value" == 'main' ]] || return 1 ;;
      Architectures) architecture_list_is_valid "$value" || return 1 ;;
      Signed-By) [[ "$value" == "$KEYRING_PATH" ]] || return 1 ;;
      *) return 1 ;;
    esac
  done < "$source_file"
  [[ "${seen[Types]-}" == 'deb' \
    && "${seen[URIs]-}" == 'https://packages.microsoft.com/repos/code' \
    && "${seen[Suites]-}" == 'stable' \
    && "${seen[Components]-}" == 'main' \
    && -n "${seen[Architectures]-}" \
    && "${seen[Signed-By]-}" == "$KEYRING_PATH" ]]
}

validate_legacy_source_file() {
  local source_file="$1" raw architecture_spec remainder
  local -a lines=()

  [[ -f "$source_file" && ! -L "$source_file" && -r "$source_file" ]] \
    || return 1
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    raw="$(trim_text "$raw")"
    [[ -z "$raw" || "$raw" == \#* ]] || lines+=("$raw")
  done < "$source_file"
  ((${#lines[@]} == 1)) || return 1
  [[ "${lines[0]}" =~ ^deb\ \[arch=([^]\ ]+)\ signed-by=/usr/share/keyrings/microsoft[.]gpg\]\ https://packages[.]microsoft[.]com/repos/code\ stable\ main$ ]] \
    || return 1
  architecture_spec="${BASH_REMATCH[1]}"
  remainder="${architecture_spec//,/ }"
  architecture_list_is_valid "$remainder"
}

validate_key_file() {
  local key_file="$1" key_data gnupg_home status

  [[ -f "$key_file" && ! -L "$key_file" && -s "$key_file" ]] || return 1
  gnupg_home="$(mktemp -d "${TMPDIR:-/tmp}/mint-jelly-vscode-gpg.XXXXXXXX")" \
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
  [[ "$(grep -c '^pub:' <<< "$key_data")" == '1' ]] || return 1
  grep -Fxq "fpr:::::::::$MICROSOFT_KEY_FINGERPRINT:" <<< "$key_data" \
    || return 1
  grep -Fq ':Microsoft (Release signing) <gpgsecurity@microsoft.com>:' \
    <<< "$key_data"
}

no_duplicate_sources() {
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
    [[ "$file" != "$SOURCE_FILE" && "$file" != "$LEGACY_SOURCE_FILE" \
      && -r "$file" ]] || continue
    if grep -Fq 'packages.microsoft.com/repos/code' "$file" 2>/dev/null; then
      printf 'Error: Duplicate VS Code APT repository configuration found: %s\n' \
        "$file" >&2
      return 1
    fi
  done
}

validate_repository_configuration() {
  local source_count=0 source_path
  local key_missing='false'

  no_duplicate_sources || return 2
  for source_path in "$SOURCE_FILE" "$LEGACY_SOURCE_FILE"; do
    [[ -e "$source_path" || -L "$source_path" ]] || continue
    ((source_count += 1))
    if [[ "$source_path" == "$SOURCE_FILE" ]]; then
      validate_source_file "$source_path" || {
        printf 'Error: VS Code APT source is unexpected or unsafe: %s\n' \
          "$source_path" >&2
        return 2
      }
    else
      validate_legacy_source_file "$source_path" || {
        printf 'Error: Legacy VS Code APT source is unexpected or unsafe: %s\n' \
          "$source_path" >&2
        return 2
      }
    fi
    path_permissions_are_safe "$source_path" \
      && path_is_root_owned "$source_path" || {
      printf 'Error: VS Code APT source permissions are unsafe: %s\n' \
        "$source_path" >&2
      return 2
    }
  done
  ((source_count <= 1)) || {
    printf 'Error: Both current and legacy VS Code APT sources are active.\n' >&2
    return 2
  }
  if [[ ! -e "$KEYRING_PATH" && ! -L "$KEYRING_PATH" ]]; then
    key_missing='true'
  else
    [[ -f "$KEYRING_PATH" && ! -L "$KEYRING_PATH" ]] \
      && path_permissions_are_safe "$KEYRING_PATH" \
      && path_is_root_owned "$KEYRING_PATH" \
      && validate_key_file "$KEYRING_PATH" || {
      printf 'Error: Microsoft APT keyring is unexpected or unsafe: %s\n' \
        "$KEYRING_PATH" >&2
      return 2
    }
  fi
  ((source_count == 1)) && [[ "$key_missing" == 'false' ]] || return 1
}

check_installation() {
  local status

  for command in dpkg dpkg-query getent gpg grep mktemp stat; do
    command -v "$command" >/dev/null 2>&1 || {
      printf 'Error: Required command not found: %s\n' "$command" >&2
      return 2
    }
  done
  if package_is_installed; then
    :
  else
    status=$?
    ((status == 1)) && return 1
    return "$status"
  fi
  validate_repository_configuration
}

verify_package_metadata() {
  local architecture homepage integrity_output maintainer rc version

  version="$(dpkg-query -W -f='${Version}' "$PACKAGE_NAME" 2>/dev/null || true)"
  architecture="$(dpkg-query -W -f='${Architecture}' "$PACKAGE_NAME" 2>/dev/null || true)"
  maintainer="$(dpkg-query -W -f='${Maintainer}' "$PACKAGE_NAME" 2>/dev/null || true)"
  homepage="$(dpkg-query -W -f='${Homepage}' "$PACKAGE_NAME" 2>/dev/null || true)"
  [[ -n "$version" ]] && dpkg --validate-version "$version" >/dev/null 2>&1 \
    || return 1
  [[ "$architecture" == 'amd64' \
    && "$maintainer" == 'Microsoft Corporation <vscode-linux@microsoft.com>' \
    && "$homepage" == 'https://code.visualstudio.com/' ]] || return 1
  if integrity_output="$(dpkg --verify "$PACKAGE_NAME" 2>&1)"; then
    [[ -z "$integrity_output" ]]
  else
    rc=$?
    printf 'Error: Installed VS Code package failed dpkg verification (status %d).\n' \
      "$rc" >&2
    return 1
  fi
}

verify_installation() {
  local package_files rc version

  if check_installation; then
    :
  else
    rc=$?
    ((rc != 1)) || printf '%s is not fully installed or configured.\n' \
      "$INSTALLER_NAME" >&2
    return "$rc"
  fi
  verify_package_metadata || {
    printf 'Error: Installed VS Code package metadata or integrity is invalid.\n' >&2
    return 2
  }
  [[ -L "$EXPECTED_COMMAND" && -x "$EXPECTED_COMMAND" \
    && "$(readlink -- "$EXPECTED_COMMAND" 2>/dev/null || true)" == "$COMMAND_TARGET" \
    && "$EXPECTED_COMMAND" -ef "$COMMAND_TARGET" ]] || {
    printf 'Error: %s does not safely target %s.\n' \
      "$EXPECTED_COMMAND" "$COMMAND_TARGET" >&2
    return 2
  }
  [[ -f "$COMMAND_TARGET" && ! -L "$COMMAND_TARGET" && -x "$COMMAND_TARGET" \
    && -f "$EXPECTED_EXECUTABLE" && ! -L "$EXPECTED_EXECUTABLE" \
    && -x "$EXPECTED_EXECUTABLE" ]] || {
    printf 'Error: Installed VS Code executables are missing or unsafe.\n' >&2
    return 2
  }
  package_files="$(dpkg-query -L "$PACKAGE_NAME" 2>/dev/null)" || return 2
  grep -Fxq "$COMMAND_TARGET" <<< "$package_files" \
    && grep -Fxq "$EXPECTED_EXECUTABLE" <<< "$package_files" || {
    printf 'Error: VS Code executables are not owned by the code package.\n' >&2
    return 2
  }
  version="$(dpkg-query -W -f='${Version}' "$PACKAGE_NAME")"
  printf '%s is installed (version %s, amd64) with Microsoft APT updates enabled.\n' \
    "$INSTALLER_NAME" "$version"
}

parse_release_metadata() {
  local metadata_file="$1"

  python3 - "$metadata_file" "$MAX_DOWNLOAD_BYTES" <<'PY'
import json
import re
import sys
from urllib.parse import urlsplit

with open(sys.argv[1], "r", encoding="utf-8") as stream:
    release = json.load(stream)

product_version = str(release.get("productVersion", ""))
commit = str(release.get("version", ""))
url = str(release.get("url", ""))
sha256 = str(release.get("sha256hash", "")).lower()

if not re.fullmatch(r"[0-9]+(?:[.][0-9]+){1,3}", product_version):
    raise SystemExit("invalid stable product version")
if release.get("name") != product_version or not re.fullmatch(r"[0-9a-f]{40}", commit):
    raise SystemExit("inconsistent stable release identity")
if not re.fullmatch(r"[0-9a-f]{64}", sha256):
    raise SystemExit("invalid SHA-256 digest")

parsed = urlsplit(url)
if parsed.scheme != "https" or parsed.netloc != "vscode.download.prss.microsoft.com":
    raise SystemExit("unexpected download host")
pattern = re.compile(
    rf"/dbazure/download/stable/{commit}/"
    rf"code_({re.escape(product_version)}-[0-9]+)_amd64[.]deb"
)
match = pattern.fullmatch(parsed.path)
if not match or parsed.query or parsed.fragment:
    raise SystemExit("unexpected stable Debian package URL")

print(product_version)
print(match.group(1))
print(url)
print(sha256)
PY
}

validate_deb() {
  local deb_file="$1" expected_package_version="$2"
  local architecture homepage maintainer package version

  [[ -f "$deb_file" && ! -L "$deb_file" && -s "$deb_file" ]] \
    || die 'Downloaded package is not a regular, non-empty file'
  dpkg-deb --info "$deb_file" >/dev/null 2>&1 \
    || die 'Downloaded file is not a valid Debian package'
  package="$(dpkg-deb -f "$deb_file" Package 2>/dev/null || true)"
  version="$(dpkg-deb -f "$deb_file" Version 2>/dev/null || true)"
  architecture="$(dpkg-deb -f "$deb_file" Architecture 2>/dev/null || true)"
  maintainer="$(dpkg-deb -f "$deb_file" Maintainer 2>/dev/null || true)"
  homepage="$(dpkg-deb -f "$deb_file" Homepage 2>/dev/null || true)"
  [[ "$package" == "$PACKAGE_NAME" \
    && "$version" == "$expected_package_version" \
    && "$architecture" == 'amd64' \
    && "$maintainer" == 'Microsoft Corporation <vscode-linux@microsoft.com>' \
    && "$homepage" == 'https://code.visualstudio.com/' ]] \
    || die 'Downloaded Debian package has unexpected identity metadata'
  dpkg --validate-version "$version" >/dev/null 2>&1 \
    || die 'Downloaded Debian package has an invalid version'
}

download_and_install_package() {
  local actual_digest deb_file expected_digest metadata_file package_version rc
  local product_version release_output release_url
  local -a release_fields=()

  require_command apt-get
  require_command curl
  require_command debconf-set-selections
  require_command dpkg
  require_command dpkg-deb
  require_command gpg
  require_command grep
  require_command mktemp
  require_command python3
  require_command sha256sum
  require_command stat
  require_command sudo
  [[ "$(dpkg --print-architecture)" == 'amd64' ]] \
    || die "$INSTALLER_NAME supports amd64 on Linux Mint"
  if validate_repository_configuration; then
    :
  else
    rc=$?
    ((rc == 1)) \
      || die 'Refusing to install over an unsafe VS Code repository configuration'
  fi

  umask 077
  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mint-jelly-vscode.XXXXXXXX")"
  metadata_file="$TEMP_DIR/release.json"
  deb_file="$TEMP_DIR/code.deb"
  log 'Resolving the current stable VS Code Debian package...'
  curl --fail --show-error --silent --location \
    --retry 3 --retry-delay 2 \
    --max-filesize "$MAX_METADATA_BYTES" \
    --proto '=https' --proto-redir '=https' \
    --output "$metadata_file" "$UPDATE_API"
  release_output="$(parse_release_metadata "$metadata_file")" \
    || die 'Microsoft returned invalid VS Code release metadata'
  mapfile -t release_fields <<< "$release_output"
  ((${#release_fields[@]} == 4)) || die 'VS Code release metadata is incomplete'
  product_version="${release_fields[0]}"
  package_version="${release_fields[1]}"
  release_url="${release_fields[2]}"
  expected_digest="${release_fields[3]}"

  log "Downloading Visual Studio Code $product_version from Microsoft..."
  curl --fail --show-error --silent --location \
    --retry 3 --retry-delay 2 \
    --max-filesize "$MAX_DOWNLOAD_BYTES" \
    --proto '=https' --proto-redir '=https' \
    --output "$deb_file" "$release_url"
  actual_digest="$(sha256sum -- "$deb_file")"
  actual_digest="${actual_digest%% *}"
  [[ "$actual_digest" == "$expected_digest" ]] \
    || die 'Downloaded VS Code package failed SHA-256 verification'
  validate_deb "$deb_file" "$package_version"
  log "Validated Microsoft VS Code package version $package_version."

  printf '%s\n' 'code code/add-microsoft-repo boolean true' \
    | sudo -- debconf-set-selections
  chmod 0644 -- "$deb_file"
  chmod 0711 -- "$TEMP_DIR"
  log 'Installing Visual Studio Code and enabling its Microsoft APT repository...'
  sudo -- env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none \
    apt-get -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confold \
      install --reinstall --yes "$deb_file"
  sudo -- env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none \
    apt-get -o Dpkg::Use-Pty=0 update
  validate_repository_configuration \
    || die 'The VS Code package did not create a valid Microsoft APT repository'
  verify_installation
}

candidate_is_from_microsoft() {
  local policy

  policy="$(LC_ALL=C apt-cache policy "$PACKAGE_NAME")" || return 1
  python3 -c '
import re
import sys

lines = sys.stdin.read().splitlines()
candidate = ""
for line in lines:
    match = re.match(r"^  Candidate: (\S+)$", line)
    if match:
        candidate = match.group(1)
        break
if not candidate or candidate == "(none)":
    raise SystemExit(1)

active = False
for line in lines:
    match = re.match(r"^\s*(?:[*]{3}\s+)?(\S+)\s+\d+\s*$", line)
    if match:
        active = match.group(1) == candidate
        continue
    if active and "https://packages.microsoft.com/repos/code" in line:
        raise SystemExit(0)
raise SystemExit(1)
' <<< "$policy"
}

install_package() {
  local rc

  ((EUID != 0)) || die 'Run this installer as the desktop user, not as root'
  if check_installation; then
    log "$INSTALLER_NAME is already installed with Microsoft APT updates; skipping."
    return 0
  else
    rc=$?
    ((rc == 1)) || return "$rc"
  fi
  if package_is_installed; then
    if validate_repository_configuration; then
      verify_installation
      return 0
    else
      rc=$?
      ((rc == 1)) || return "$rc"
    fi
  fi
  download_and_install_package
}

update_package() {
  local rc

  ((EUID != 0)) || die 'Run this installer as the desktop user, not as root'
  if check_installation; then
    :
  else
    rc=$?
    if ((rc == 1)); then
      download_and_install_package
      return
    fi
    return "$rc"
  fi
  require_command apt-cache
  require_command apt-get
  require_command python3
  require_command sudo
  log 'Refreshing the Microsoft VS Code APT repository...'
  sudo -- env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none \
    apt-get -o Dpkg::Use-Pty=0 update
  candidate_is_from_microsoft \
    || die 'The VS Code APT candidate is not supplied by packages.microsoft.com'
  log 'Updating Visual Studio Code through APT...'
  sudo -- env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none \
    apt-get -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confold \
      install --only-upgrade --yes "$PACKAGE_NAME"
  verify_installation
}

microsoft_key_is_referenced() {
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
    [[ -r "$file" ]] || continue
    grep -Fq "$KEYRING_PATH" "$file" 2>/dev/null && return 0
  done
  return 1
}

remove_repository_artifacts() {
  local source_path

  for source_path in "$SOURCE_FILE" "$LEGACY_SOURCE_FILE"; do
    [[ -e "$source_path" || -L "$source_path" ]] || continue
    if [[ "$source_path" == "$SOURCE_FILE" ]] \
      && validate_source_file "$source_path" \
      && path_permissions_are_safe "$source_path" \
      && path_is_root_owned "$source_path"; then
      sudo -- rm -f -- "$source_path"
    elif [[ "$source_path" == "$LEGACY_SOURCE_FILE" ]] \
      && validate_legacy_source_file "$source_path" \
      && path_permissions_are_safe "$source_path" \
      && path_is_root_owned "$source_path"; then
      sudo -- rm -f -- "$source_path"
    else
      warn "Leaving unexpected VS Code repository file untouched: $source_path"
    fi
  done
  if [[ -e "$KEYRING_PATH" || -L "$KEYRING_PATH" ]]; then
    if microsoft_key_is_referenced; then
      warn "Keeping shared Microsoft keyring because another APT source references it: $KEYRING_PATH"
    elif [[ -f "$KEYRING_PATH" && ! -L "$KEYRING_PATH" ]] \
      && validate_key_file "$KEYRING_PATH" \
      && path_permissions_are_safe "$KEYRING_PATH" \
      && path_is_root_owned "$KEYRING_PATH"; then
      sudo -- rm -f -- "$KEYRING_PATH"
    else
      warn "Leaving unexpected Microsoft keyring untouched: $KEYRING_PATH"
    fi
  fi
}

uninstall_package() {
  local rc

  ((EUID != 0)) || die 'Run this installer as the desktop user, not as root'
  require_command apt-get
  require_command dpkg-query
  require_command sudo
  if [[ "${MINT_JELLY_PURGE:-false}" == 'true' ]]; then
    require_command pgrep
    if pgrep -u "$UID" -x code >/dev/null 2>&1; then
      die 'Close Visual Studio Code before purging its configuration'
    fi
  fi
  if package_is_installed; then
    if [[ "${MINT_JELLY_PURGE:-false}" == 'true' ]]; then
      sudo -- env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none \
        apt-get -o Dpkg::Use-Pty=0 purge --yes "$PACKAGE_NAME"
    else
      sudo -- env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none \
        apt-get -o Dpkg::Use-Pty=0 remove --yes "$PACKAGE_NAME"
    fi
  else
    rc=$?
    ((rc == 1)) || return "$rc"
  fi
  remove_repository_artifacts
  if [[ "${MINT_JELLY_PURGE:-false}" == 'true' ]]; then
    rm -rf -- "$HOME/.config/Code" "$HOME/.vscode"
  fi
}

cleanup() {
  local status=$?

  trap - EXIT HUP INT TERM
  [[ -z "$TEMP_DIR" || ! -d "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"
  exit "$status"
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
      install_package
      ;;
    update)
      (($# == 1)) || { usage; return 64; }
      update_package
      ;;
    uninstall)
      (($# == 1)) || { usage; return 64; }
      uninstall_package
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
