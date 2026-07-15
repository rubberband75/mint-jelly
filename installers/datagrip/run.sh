#!/usr/bin/env bash

set -Eeuo pipefail

readonly INSTALLER_NAME="DataGrip"
readonly RELEASE_API="https://data.services.jetbrains.com/products/releases?code=DG&latest=true&type=release"
readonly STABLE_LINK="/opt/datagrip"
readonly COMMAND_LINK="/usr/local/bin/datagrip"
readonly MAX_METADATA_BYTES="10485760"
readonly MAX_CHECKSUM_BYTES="4096"
readonly MAX_DOWNLOAD_BYTES="2147483648"
readonly MAX_ARCHIVE_MEMBERS="250000"
readonly MAX_EXTRACTED_BYTES="6442450944"

TEMP_DIR=""
SYSTEM_PENDING_DIR=""
SYSTEM_TARGET_DIR=""
SYSTEM_STABLE_BACKUP=""
SYSTEM_COMMAND_BACKUP=""
SYSTEM_TRANSACTION_ACTIVE='false'
SYSTEM_TARGET_CREATED='false'
SYSTEM_STABLE_CREATED='false'
SYSTEM_COMMAND_CREATED='false'
SYSTEM_HAD_STABLE='false'
SYSTEM_HAD_COMMAND='false'

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

read_product_fields() {
  local product_file="$1/product-info.json"

  [[ -f "$product_file" && ! -L "$product_file" ]] || return 1
  python3 - "$product_file" <<'PY'
import json
import re
import sys

with open(sys.argv[1], "r", encoding="utf-8") as stream:
    product = json.load(stream)

if (
    product.get("name") != "DataGrip"
    or product.get("productCode") != "DB"
    or product.get("productVendor") != "JetBrains"
):
    raise SystemExit("unexpected JetBrains product metadata")

version = str(product.get("version", ""))
if not re.fullmatch(r"[0-9]+(?:[.][0-9]+)+", version):
    raise SystemExit("invalid DataGrip version metadata")
build = str(product.get("buildNumber", ""))
if not re.fullmatch(r"[0-9]+(?:[.][0-9]+)+", build):
    raise SystemExit("invalid DataGrip build metadata")

launchers = [
    item for item in product.get("launch", [])
    if item.get("os") == "Linux" and item.get("arch") == "amd64"
]
if len(launchers) != 1:
    raise SystemExit("expected exactly one amd64 Linux launcher")

launcher = str(launchers[0].get("launcherPath", ""))
if launcher not in {"bin/datagrip", "bin/datagrip.sh"}:
    raise SystemExit("unexpected DataGrip launcher path")
java_executable = str(launchers[0].get("javaExecutablePath", ""))
if java_executable != "jbr/bin/java":
    raise SystemExit("unexpected bundled Java path")

icon = str(product.get("svgIconPath", ""))
if icon and icon != "bin/datagrip.svg":
    raise SystemExit("unexpected DataGrip icon path")

startup_class = str(launchers[0].get("startupWmClass", "jetbrains-datagrip"))
if not re.fullmatch(r"[A-Za-z0-9_.-]+", startup_class):
    raise SystemExit("invalid DataGrip startup window class")

print(version)
print(launcher)
print(icon)
print(startup_class)
print(java_executable)
PY
}

inspect_installation() {
  local link_target resolved_target target_version launcher_path icon_path startup_class
  local java_path product_output
  local -a fields=()

  [[ -L "$STABLE_LINK" ]] || {
    printf 'Error: %s must be a symbolic link to a versioned DataGrip directory.\n' "$STABLE_LINK" >&2
    return 2
  }
  link_target="$(readlink -- "$STABLE_LINK" 2>/dev/null || true)"
  [[ "$link_target" =~ ^/opt/DataGrip-([0-9]+([.][0-9]+)+)$ ]] || {
    printf 'Error: %s has an unexpected target: %s\n' "$STABLE_LINK" "${link_target:-unreadable}" >&2
    return 2
  }
  target_version="${BASH_REMATCH[1]}"
  resolved_target="$(readlink -f -- "$STABLE_LINK" 2>/dev/null || true)"
  [[ "$resolved_target" == "$link_target" && -d "$resolved_target" && ! -L "$resolved_target" ]] || {
    printf 'Error: The versioned DataGrip installation is missing or unsafe: %s\n' "$link_target" >&2
    return 2
  }
  path_permissions_are_safe "$resolved_target" || {
    printf 'Error: The DataGrip installation directory is group- or world-writable: %s\n' "$resolved_target" >&2
    return 2
  }
  command -v python3 >/dev/null 2>&1 || {
    printf 'Error: Required command not found: python3\n' >&2
    return 2
  }
  if ! product_output="$(read_product_fields "$resolved_target")"; then
    printf 'Error: DataGrip product metadata is invalid under %s.\n' "$resolved_target" >&2
    return 2
  fi
  mapfile -t fields <<< "$product_output"
  ((${#fields[@]} == 5)) || {
    printf 'Error: DataGrip product metadata is incomplete under %s.\n' "$resolved_target" >&2
    return 2
  }
  [[ "${fields[0]}" == "$target_version" ]] || {
    printf 'Error: DataGrip directory version and product metadata do not match.\n' >&2
    return 2
  }
  launcher_path="$resolved_target/${fields[1]}"
  icon_path="${fields[2]}"
  startup_class="${fields[3]}"
  java_path="$resolved_target/${fields[4]}"
  [[ -f "$launcher_path" && ! -L "$launcher_path" && -x "$launcher_path" ]] || {
    printf 'Error: The DataGrip launcher is missing or unsafe: %s\n' "$launcher_path" >&2
    return 2
  }
  path_permissions_are_safe "$launcher_path" || {
    printf 'Error: The DataGrip launcher is group- or world-writable: %s\n' "$launcher_path" >&2
    return 2
  }
  path_permissions_are_safe "$resolved_target/product-info.json" || {
    printf 'Error: DataGrip product metadata is group- or world-writable.\n' >&2
    return 2
  }
  [[ -f "$java_path" && ! -L "$java_path" && -x "$java_path" ]] || {
    printf 'Error: The bundled DataGrip Java runtime is missing or unsafe: %s\n' "$java_path" >&2
    return 2
  }
  path_permissions_are_safe "$java_path" || {
    printf 'Error: The bundled DataGrip Java runtime is group- or world-writable.\n' >&2
    return 2
  }
  if [[ -n "$icon_path" ]]; then
    [[ -f "$resolved_target/$icon_path" && ! -L "$resolved_target/$icon_path" ]] || {
      printf 'Error: The declared DataGrip icon is missing or unsafe.\n' >&2
      return 2
    }
    path_permissions_are_safe "$resolved_target/$icon_path" || {
      printf 'Error: The declared DataGrip icon is group- or world-writable.\n' >&2
      return 2
    }
  fi
  [[ -L "$COMMAND_LINK" && -x "$COMMAND_LINK" && "$COMMAND_LINK" -ef "$launcher_path" ]] || {
    printf 'Error: %s is missing or does not target the active DataGrip launcher.\n' "$COMMAND_LINK" >&2
    return 2
  }

  printf '%s\n%s\n%s\n%s\n%s\n' \
    "$target_version" "$resolved_target" "$launcher_path" "$icon_path" "$startup_class"
}

check_installation() {
  if [[ ! -e "$STABLE_LINK" && ! -L "$STABLE_LINK" \
    && ! -e "$COMMAND_LINK" && ! -L "$COMMAND_LINK" ]]; then
    return 1
  fi
  inspect_installation >/dev/null
}

verify_installation() {
  local details_output rc
  local -a details=()

  if check_installation; then
    :
  else
    rc=$?
    if ((rc == 1)); then
      printf '%s is not installed.\n' "$INSTALLER_NAME" >&2
    fi
    return "$rc"
  fi
  details_output="$(inspect_installation)" || return $?
  mapfile -t details <<< "$details_output"
  ((${#details[@]} == 5)) || return 2
  printf '%s is installed (version %s at %s).\n' \
    "$INSTALLER_NAME" "${details[0]}" "$COMMAND_LINK"
}

parse_release_metadata() {
  local metadata_file="$1"

  python3 - "$metadata_file" "$MAX_DOWNLOAD_BYTES" <<'PY'
import json
import re
import sys

with open(sys.argv[1], "r", encoding="utf-8") as stream:
    document = json.load(stream)

releases = document.get("DG") if isinstance(document, dict) else None
if not isinstance(releases, list) or len(releases) != 1:
    raise SystemExit("expected exactly one latest stable DataGrip release")

release = releases[0]
version = str(release.get("version", ""))
if release.get("type") != "release" or not re.fullmatch(r"[0-9]+(?:[.][0-9]+)+", version):
    raise SystemExit("invalid stable DataGrip release metadata")

downloads = release.get("downloads")
linux = downloads.get("linux") if isinstance(downloads, dict) else None
if not isinstance(linux, dict):
    raise SystemExit("release has no amd64 Linux download")

archive_url = str(linux.get("link", ""))
checksum_url = str(linux.get("checksumLink", ""))
size = linux.get("size")
expected_url = f"https://download.jetbrains.com/datagrip/datagrip-{version}.tar.gz"
if archive_url != expected_url or checksum_url != expected_url + ".sha256":
    raise SystemExit("release returned an unexpected JetBrains download URL")
if not isinstance(size, int) or isinstance(size, bool) or size <= 0 or size > int(sys.argv[2]):
    raise SystemExit("release returned an invalid or excessive download size")

print(version)
print(archive_url)
print(checksum_url)
print(size)
PY
}

read_checksum() {
  local checksum_file="$1"
  local archive_name="$2"
  local checksum_name expected extra
  local -a lines=()

  mapfile -t lines < "$checksum_file"
  ((${#lines[@]} == 1)) || return 1
  read -r expected checksum_name extra <<< "${lines[0]}"
  checksum_name="${checksum_name#\*}"
  [[ "$expected" =~ ^[A-Fa-f0-9]{64}$ \
    && "$checksum_name" == "$archive_name" && -z "$extra" ]] || return 1
  printf '%s\n' "${expected,,}"
}

extract_validated_archive() {
  local archive="$1"
  local destination="$2"
  local top_level="$3"

  python3 - "$archive" "$destination" "$top_level" \
    "$MAX_ARCHIVE_MEMBERS" "$MAX_EXTRACTED_BYTES" <<'PY'
import posixpath
import sys
import tarfile

archive_path, destination, top_level = sys.argv[1:4]
max_members = int(sys.argv[4])
max_extracted_bytes = int(sys.argv[5])

if not hasattr(tarfile, "data_filter"):
    raise SystemExit("Python tar extraction filters are unavailable")

with tarfile.open(archive_path, mode="r:gz") as bundle:
    members = bundle.getmembers()
    if not members:
        raise SystemExit("archive is empty")
    if len(members) > max_members:
        raise SystemExit(f"archive contains too many entries: {len(members)}")

    extracted_bytes = 0
    for member in members:
        raw_name = member.name
        if not raw_name or raw_name.startswith("/"):
            raise SystemExit(f"unsafe archive path: {raw_name!r}")

        normalized = posixpath.normpath(raw_name)
        if normalized != top_level and not normalized.startswith(top_level + "/"):
            raise SystemExit(f"archive entry is outside {top_level}/: {raw_name!r}")
        if member.isdev() or member.isfifo() or member.islnk():
            raise SystemExit(f"archive contains an unsafe special entry: {raw_name!r}")
        if member.size < 0:
            raise SystemExit(f"archive entry has a negative size: {raw_name!r}")
        extracted_bytes += member.size
        if extracted_bytes > max_extracted_bytes:
            raise SystemExit("archive expands beyond the configured safety limit")

        if member.issym():
            link_name = member.linkname
            if not link_name or link_name.startswith("/"):
                raise SystemExit(f"unsafe archive link: {raw_name!r}")
            target = posixpath.normpath(
                posixpath.join(posixpath.dirname(normalized), link_name)
            )
            if target != top_level and not target.startswith(top_level + "/"):
                raise SystemExit(f"archive link escapes {top_level}/: {raw_name!r}")

    bundle.extractall(path=destination, members=members, filter="data")
PY
}

write_desktop_file() {
  local version="$1"
  local icon_path="$2"
  local startup_class="$3"
  local data_home desktop_dir desktop_file temp_file

  data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
  [[ "$data_home" == /* ]] || {
    printf 'XDG_DATA_HOME must be an absolute path.\n' >&2
    return 1
  }
  desktop_dir="$data_home/applications"
  desktop_file="$desktop_dir/jetbrains-datagrip.desktop"
  install -d -m 0755 "$desktop_dir" || return 1
  temp_file="$(mktemp "$desktop_dir/.jetbrains-datagrip.desktop.XXXXXXXX")" || return 1

  {
    printf '%s\n' '[Desktop Entry]'
    printf '%s\n' 'Type=Application'
    printf '%s\n' 'Version=1.0'
    printf 'X-AppVersion=%s\n' "$version"
    printf '%s\n' 'Name=DataGrip'
    printf '%s\n' 'Comment=JetBrains DataGrip IDE'
    printf 'Exec=%s\n' "$COMMAND_LINK"
    printf '%s\n' 'Terminal=false'
    if [[ -n "$icon_path" && -f "$STABLE_LINK/$icon_path" ]]; then
      printf 'Icon=%s/%s\n' "$STABLE_LINK" "$icon_path"
    fi
    printf '%s\n' 'Categories=Development;IDE;Database;'
    printf 'StartupWMClass=%s\n' "$startup_class"
  } >"$temp_file" || {
    rm -f -- "$temp_file"
    return 1
  }
  chmod 0644 "$temp_file" || {
    rm -f -- "$temp_file"
    return 1
  }
  mv -f -- "$temp_file" "$desktop_file"
}

rollback_system_transaction() {
  local rollback_ok='true'

  [[ "$SYSTEM_TRANSACTION_ACTIVE" == 'true' ]] || return 0
  warn 'Rolling back the interrupted DataGrip system installation.'

  if [[ "$SYSTEM_COMMAND_CREATED" == 'true' ]]; then
    sudo -n -- rm -f -- "$COMMAND_LINK" 2>/dev/null || rollback_ok='false'
  fi
  if [[ "$SYSTEM_HAD_COMMAND" == 'true' \
    && ( -e "$SYSTEM_COMMAND_BACKUP" || -L "$SYSTEM_COMMAND_BACKUP" ) ]]; then
    sudo -n -- mv -- "$SYSTEM_COMMAND_BACKUP" "$COMMAND_LINK" 2>/dev/null \
      || rollback_ok='false'
  fi

  if [[ "$SYSTEM_STABLE_CREATED" == 'true' ]]; then
    sudo -n -- rm -f -- "$STABLE_LINK" 2>/dev/null || rollback_ok='false'
  fi
  if [[ "$SYSTEM_HAD_STABLE" == 'true' \
    && ( -e "$SYSTEM_STABLE_BACKUP" || -L "$SYSTEM_STABLE_BACKUP" ) ]]; then
    sudo -n -- mv -- "$SYSTEM_STABLE_BACKUP" "$STABLE_LINK" 2>/dev/null \
      || rollback_ok='false'
  fi

  if [[ "$SYSTEM_TARGET_CREATED" == 'true' \
    && ( -e "$SYSTEM_TARGET_DIR" || -L "$SYSTEM_TARGET_DIR" ) ]]; then
    sudo -n -- rm -rf -- "$SYSTEM_TARGET_DIR" 2>/dev/null || rollback_ok='false'
  fi
  if [[ -n "$SYSTEM_PENDING_DIR" \
    && ( -e "$SYSTEM_PENDING_DIR" || -L "$SYSTEM_PENDING_DIR" ) ]]; then
    sudo -n -- rm -rf -- "$SYSTEM_PENDING_DIR" 2>/dev/null || rollback_ok='false'
  fi

  [[ "$rollback_ok" == 'true' ]] || {
    warn "Automatic rollback was incomplete. Inspect $SYSTEM_TARGET_DIR and the DataGrip links."
    return 1
  }
}

cleanup() {
  local status=$?

  trap - EXIT HUP INT TERM
  if ! rollback_system_transaction; then
    ((status == 0)) && status=2
  fi
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
  exit "$status"
}

activate_bundle() {
  local source_dir="$1"
  local version="$2"
  local launcher_path="$3"

  SYSTEM_PENDING_DIR="/opt/.mint-jelly-datagrip-new-$$"
  SYSTEM_TARGET_DIR="/opt/DataGrip-$version"
  SYSTEM_STABLE_BACKUP="/opt/.mint-jelly-datagrip-link-old-$$"
  SYSTEM_COMMAND_BACKUP="/usr/local/bin/.mint-jelly-datagrip-old-$$"

  if [[ -e "$SYSTEM_PENDING_DIR" || -L "$SYSTEM_PENDING_DIR" \
    || -e "$SYSTEM_TARGET_DIR" || -L "$SYSTEM_TARGET_DIR" \
    || -e "$SYSTEM_STABLE_BACKUP" || -L "$SYSTEM_STABLE_BACKUP" \
    || -e "$SYSTEM_COMMAND_BACKUP" || -L "$SYSTEM_COMMAND_BACKUP" ]]; then
    die 'Refusing to overwrite an existing DataGrip target or transaction path'
  fi
  if [[ -e "$STABLE_LINK" && ! -L "$STABLE_LINK" ]]; then
    die "Refusing to overwrite non-symlink path: $STABLE_LINK"
  fi
  if [[ -e "$COMMAND_LINK" && ! -L "$COMMAND_LINK" ]]; then
    die "Refusing to overwrite non-symlink path: $COMMAND_LINK"
  fi

  [[ ! -e "$STABLE_LINK" && ! -L "$STABLE_LINK" ]] || SYSTEM_HAD_STABLE='true'
  [[ ! -e "$COMMAND_LINK" && ! -L "$COMMAND_LINK" ]] || SYSTEM_HAD_COMMAND='true'
  SYSTEM_TRANSACTION_ACTIVE='true'

  sudo -- install -d -m 0755 "$SYSTEM_PENDING_DIR"
  sudo -- cp -R --no-preserve=ownership -- "$source_dir"/. "$SYSTEM_PENDING_DIR"/ \
    || die 'Could not stage the DataGrip application bundle'
  [[ -f "$SYSTEM_PENDING_DIR/$launcher_path" \
    && ! -L "$SYSTEM_PENDING_DIR/$launcher_path" \
    && -x "$SYSTEM_PENDING_DIR/$launcher_path" ]] \
    || die 'The staged DataGrip launcher is missing or unsafe'

  if [[ "$SYSTEM_HAD_STABLE" == 'true' ]]; then
    sudo -- mv -- "$STABLE_LINK" "$SYSTEM_STABLE_BACKUP"
  fi
  if [[ "$SYSTEM_HAD_COMMAND" == 'true' ]]; then
    sudo -- mv -- "$COMMAND_LINK" "$SYSTEM_COMMAND_BACKUP"
  fi

  SYSTEM_TARGET_CREATED='true'
  sudo -- mv -- "$SYSTEM_PENDING_DIR" "$SYSTEM_TARGET_DIR" \
    || die 'Could not activate the versioned DataGrip directory'
  SYSTEM_STABLE_CREATED='true'
  sudo -- ln -sT -- "$SYSTEM_TARGET_DIR" "$STABLE_LINK" \
    || die 'Could not create the stable DataGrip link'
  SYSTEM_COMMAND_CREATED='true'
  sudo -- ln -sT -- "$STABLE_LINK/$launcher_path" "$COMMAND_LINK" \
    || die 'Could not create the DataGrip command link'

  verify_installation >/dev/null \
    || die 'The activated DataGrip installation did not pass verification'
  SYSTEM_TRANSACTION_ACTIVE='false'

  [[ ! -e "$SYSTEM_STABLE_BACKUP" && ! -L "$SYSTEM_STABLE_BACKUP" ]] \
    || sudo -- rm -f -- "$SYSTEM_STABLE_BACKUP" \
    || warn "Could not remove old stable-link backup: $SYSTEM_STABLE_BACKUP"
  [[ ! -e "$SYSTEM_COMMAND_BACKUP" && ! -L "$SYSTEM_COMMAND_BACKUP" ]] \
    || sudo -- rm -f -- "$SYSTEM_COMMAND_BACKUP" \
    || warn "Could not remove old command-link backup: $SYSTEM_COMMAND_BACKUP"
}

install_bundle() {
  local actual_digest architecture archive_file archive_name archive_size
  local checksum_file checksum_url expected_digest metadata_file rc source_dir
  local version launcher_path icon_path startup_class metadata_output product_output
  local -a product_fields=() release_fields=()

  if check_installation; then
    log "$INSTALLER_NAME is already installed; skipping."
    return 0
  else
    rc=$?
    ((rc == 1)) || return "$rc"
  fi

  ((EUID != 0)) || die 'Run this installer as the desktop user, not as root'
  require_command cp
  require_command curl
  require_command dpkg
  require_command install
  require_command ln
  require_command mktemp
  require_command mv
  require_command python3
  require_command sha256sum
  require_command stat
  require_command sudo

  architecture="$(dpkg --print-architecture)"
  [[ "$architecture" == 'amd64' ]] \
    || die "$INSTALLER_NAME supports amd64 on Linux Mint; detected $architecture"

  umask 077
  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mint-jelly-datagrip.XXXXXXXX")"
  metadata_file="$TEMP_DIR/releases.json"
  checksum_file="$TEMP_DIR/datagrip.sha256"

  log 'Resolving the latest stable DataGrip release from JetBrains...'
  curl --fail --show-error --silent --location \
    --retry 3 --retry-delay 2 \
    --max-filesize "$MAX_METADATA_BYTES" \
    --proto '=https' --proto-redir '=https' \
    --user-agent 'mint-jelly-installer' \
    --output "$metadata_file" "$RELEASE_API"
  (($(stat -c '%s' -- "$metadata_file") <= MAX_METADATA_BYTES)) \
    || die 'JetBrains release metadata exceeded the safety limit'

  if ! metadata_output="$(parse_release_metadata "$metadata_file")"; then
    die 'Could not validate the latest stable DataGrip release metadata'
  fi
  mapfile -t release_fields <<< "$metadata_output"
  ((${#release_fields[@]} == 4)) || die 'DataGrip release metadata was incomplete'
  version="${release_fields[0]}"
  archive_file="$TEMP_DIR/datagrip-$version.tar.gz"
  archive_name="${archive_file##*/}"
  checksum_url="${release_fields[2]}"
  archive_size="${release_fields[3]}"

  log "Downloading the official checksum for DataGrip $version..."
  curl --fail --show-error --silent --location \
    --retry 3 --retry-delay 2 \
    --max-filesize "$MAX_CHECKSUM_BYTES" \
    --proto '=https' --proto-redir '=https' \
    --output "$checksum_file" "$checksum_url"
  (($(stat -c '%s' -- "$checksum_file") <= MAX_CHECKSUM_BYTES)) \
    || die 'DataGrip checksum file exceeded the safety limit'
  expected_digest="$(read_checksum "$checksum_file" "$archive_name" || true)"
  [[ -n "$expected_digest" ]] || die 'JetBrains checksum file had an unexpected format or filename'

  log "Downloading DataGrip $version from JetBrains (approximately $((archive_size / 1024 / 1024)) MiB)..."
  curl --fail --show-error --silent --location \
    --retry 3 --retry-delay 2 \
    --max-filesize "$MAX_DOWNLOAD_BYTES" \
    --proto '=https' --proto-redir '=https' \
    --output "$archive_file" "${release_fields[1]}"
  [[ "$(stat -c '%s' -- "$archive_file")" == "$archive_size" ]] \
    || die 'Downloaded DataGrip archive size does not match JetBrains release metadata'
  actual_digest="$(sha256sum "$archive_file")"
  actual_digest="${actual_digest%% *}"
  [[ "${actual_digest,,}" == "$expected_digest" ]] \
    || die 'DataGrip archive SHA-256 verification failed'
  log 'Verified the required JetBrains SHA-256 digest.'

  extract_validated_archive "$archive_file" "$TEMP_DIR" "DataGrip-$version" \
    || die 'Downloaded file is not a safe DataGrip gzip archive'
  source_dir="$TEMP_DIR/DataGrip-$version"
  [[ -d "$source_dir" && ! -L "$source_dir" ]] \
    || die 'DataGrip archive has an unexpected top-level layout'
  if ! product_output="$(read_product_fields "$source_dir")"; then
    die 'DataGrip archive has invalid product metadata'
  fi
  mapfile -t product_fields <<< "$product_output"
  ((${#product_fields[@]} == 5)) || die 'DataGrip archive product metadata was incomplete'
  [[ "${product_fields[0]}" == "$version" ]] \
    || die 'DataGrip release version and archive product version do not match'
  launcher_path="${product_fields[1]}"
  icon_path="${product_fields[2]}"
  startup_class="${product_fields[3]}"
  [[ -f "$source_dir/$launcher_path" && ! -L "$source_dir/$launcher_path" \
    && -x "$source_dir/$launcher_path" ]] \
    || die 'DataGrip archive has no valid amd64 Linux launcher'
  [[ -f "$source_dir/${product_fields[4]}" && ! -L "$source_dir/${product_fields[4]}" \
    && -x "$source_dir/${product_fields[4]}" ]] \
    || die 'DataGrip archive has no valid bundled Java runtime'

  log "Installing $INSTALLER_NAME $version..."
  activate_bundle "$source_dir" "$version" "$launcher_path"
  if ! write_desktop_file "$version" "$icon_path" "$startup_class"; then
    warn 'DataGrip was installed, but its per-user desktop launcher could not be written.'
  fi
  log 'DataGrip will request a JetBrains license or trial when first launched.'
  verify_installation
}

usage() {
  printf 'Usage: %s {check|install|verify}\n' "${0##*/}" >&2
}

main() {
  trap cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  (($# == 1)) || {
    usage
    return 64
  }
  case "$1" in
    check) check_installation ;;
    install) install_bundle ;;
    verify) verify_installation ;;
    *)
      usage
      return 64
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
