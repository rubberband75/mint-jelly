#!/usr/bin/env bash

set -Eeuo pipefail

readonly INSTALLER_NAME="Postman"
readonly DOWNLOAD_URL="https://dl.pstmn.io/download/latest/linux64"
readonly INSTALL_DIR="/opt/Postman"
readonly CANONICAL_EXECUTABLE="$INSTALL_DIR/app/Postman"
readonly COMMAND_LINK="/usr/local/bin/postman"
readonly MAX_DOWNLOAD_BYTES="1073741824"
readonly MAX_ARCHIVE_MEMBERS="100000"
readonly MAX_EXTRACTED_BYTES="4294967296"

TEMP_DIR=""
SYSTEM_PENDING_DIR=""
SYSTEM_BACKUP_DIR=""
SYSTEM_LINK_BACKUP=""
SYSTEM_TRANSACTION_ACTIVE='false'
SYSTEM_HAD_INSTALL='false'
SYSTEM_HAD_LINK='false'
SYSTEM_NEW_INSTALL_MAY_EXIST='false'
SYSTEM_NEW_LINK_MAY_EXIST='false'

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

rollback_system_transaction() {
  local rollback_ok='true'

  [[ "$SYSTEM_TRANSACTION_ACTIVE" == 'true' ]] || return 0
  warn 'Rolling back the interrupted Postman system installation.'

  if [[ "$SYSTEM_HAD_LINK" == 'true' ]]; then
    if [[ -e "$SYSTEM_LINK_BACKUP" || -L "$SYSTEM_LINK_BACKUP" ]]; then
      sudo -n -- rm -f -- "$COMMAND_LINK" 2>/dev/null || rollback_ok='false'
      sudo -n -- mv -- "$SYSTEM_LINK_BACKUP" "$COMMAND_LINK" 2>/dev/null || rollback_ok='false'
    fi
  elif [[ "$SYSTEM_NEW_LINK_MAY_EXIST" == 'true' && ( -e "$COMMAND_LINK" || -L "$COMMAND_LINK" ) ]]; then
    sudo -n -- rm -f -- "$COMMAND_LINK" 2>/dev/null || rollback_ok='false'
  fi

  if [[ "$SYSTEM_HAD_INSTALL" == 'true' ]]; then
    if [[ -e "$SYSTEM_BACKUP_DIR" || -L "$SYSTEM_BACKUP_DIR" ]]; then
      if [[ -e "$INSTALL_DIR" || -L "$INSTALL_DIR" ]]; then
        sudo -n -- rm -rf -- "$INSTALL_DIR" 2>/dev/null || rollback_ok='false'
      fi
      sudo -n -- mv -- "$SYSTEM_BACKUP_DIR" "$INSTALL_DIR" 2>/dev/null || rollback_ok='false'
    fi
  elif [[ "$SYSTEM_NEW_INSTALL_MAY_EXIST" == 'true' && ( -e "$INSTALL_DIR" || -L "$INSTALL_DIR" ) ]]; then
    sudo -n -- rm -rf -- "$INSTALL_DIR" 2>/dev/null || rollback_ok='false'
  fi

  if [[ -n "$SYSTEM_PENDING_DIR" && ( -e "$SYSTEM_PENDING_DIR" || -L "$SYSTEM_PENDING_DIR" ) ]]; then
    sudo -n -- rm -rf -- "$SYSTEM_PENDING_DIR" 2>/dev/null || rollback_ok='false'
  fi

  if [[ "$rollback_ok" != 'true' ]]; then
    warn "Automatic rollback was incomplete. Inspect: $INSTALL_DIR, $SYSTEM_BACKUP_DIR, $SYSTEM_PENDING_DIR, and $SYSTEM_LINK_BACKUP"
    return 1
  fi
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

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

check_installation() {
  local has_artifact='false' top_level_target version

  if [[ -e "$INSTALL_DIR" || -L "$INSTALL_DIR" || -e "$COMMAND_LINK" || -L "$COMMAND_LINK" ]]; then
    has_artifact='true'
  fi
  [[ "$has_artifact" == 'true' ]] || return 1

  if [[ ! -d "$INSTALL_DIR" || -L "$INSTALL_DIR" \
    || ! -f "$CANONICAL_EXECUTABLE" || -L "$CANONICAL_EXECUTABLE" \
    || ! -x "$CANONICAL_EXECUTABLE" ]]; then
    printf 'Error: The Postman installation under %s is incomplete or unsafe.\n' "$INSTALL_DIR" >&2
    return 2
  fi
  if [[ -e "$INSTALL_DIR/Postman" || -L "$INSTALL_DIR/Postman" ]]; then
    if [[ ! -L "$INSTALL_DIR/Postman" ]]; then
      printf 'Error: The optional top-level Postman launcher is not a symbolic link.\n' >&2
      return 2
    fi
    top_level_target="$(readlink -- "$INSTALL_DIR/Postman" 2>/dev/null || true)"
    if [[ -z "$top_level_target" || "$top_level_target" == /* \
      || ! "$INSTALL_DIR/Postman" -ef "$CANONICAL_EXECUTABLE" ]]; then
      printf 'Error: The top-level Postman launcher is not a safe relative link to app/Postman.\n' >&2
      return 2
    fi
  fi
  if [[ ! -L "$COMMAND_LINK" || ! -x "$COMMAND_LINK" \
    || ! "$COMMAND_LINK" -ef "$CANONICAL_EXECUTABLE" ]]; then
    printf 'Error: The Postman command link is missing or does not target %s.\n' "$CANONICAL_EXECUTABLE" >&2
    return 2
  fi
  if ! version="$(read_bundle_version "$INSTALL_DIR")"; then
    printf 'Error: The Postman installation has no valid bundle version metadata.\n' >&2
    return 2
  fi
}

read_package_version() {
  local json pattern
  local package_json="$1"

  [[ -f "$package_json" && ! -L "$package_json" ]] || return 1
  json="$(<"$package_json")"
  pattern='"version"[[:space:]]*:[[:space:]]*"([0-9]+([.][0-9]+)+([-+][A-Za-z0-9._-]+)?)"'
  if [[ "$json" =~ $pattern ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

read_bundle_version() {
  local bundle_dir="$1"
  local candidate

  for candidate in \
    "$bundle_dir/app/resources/app/package.json" \
    "$bundle_dir/resources/app/package.json"; do
    if read_package_version "$candidate"; then
      return 0
    fi
  done

  return 1
}

verify_installation() {
  local rc version

  if check_installation; then
    :
  else
    rc=$?
    if ((rc == 1)); then
      printf '%s is not installed.\n' "$INSTALLER_NAME" >&2
    fi
    return "$rc"
  fi

  version="$(read_bundle_version "$INSTALL_DIR")"
  printf '%s is installed (version %s at %s).\n' "$INSTALLER_NAME" "$version" "$COMMAND_LINK"
}

extract_validated_archive() {
  local archive="$1"
  local destination="$2"

  python3 - "$archive" "$destination" "$MAX_ARCHIVE_MEMBERS" "$MAX_EXTRACTED_BYTES" <<'PY'
import posixpath
import sys
import tarfile

archive_path, destination = sys.argv[1:3]
max_members = int(sys.argv[3])
max_extracted_bytes = int(sys.argv[4])

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
        parts = normalized.split("/")
        if normalized == ".." or normalized.startswith("../") or parts[0] != "Postman":
            raise SystemExit(f"archive entry is outside Postman/: {raw_name!r}")
        if member.isdev() or member.isfifo():
            raise SystemExit(f"archive contains a special device or FIFO: {raw_name!r}")
        if member.size < 0:
            raise SystemExit(f"archive entry has a negative size: {raw_name!r}")
        extracted_bytes += member.size
        if extracted_bytes > max_extracted_bytes:
            raise SystemExit("archive expands beyond the configured safety limit")

        if member.issym() or member.islnk():
            link_name = member.linkname
            if not link_name or link_name.startswith("/"):
                raise SystemExit(f"unsafe archive link: {raw_name!r}")
            target = posixpath.normpath(posixpath.join(posixpath.dirname(normalized), link_name))
            if target != "Postman" and not target.startswith("Postman/"):
                raise SystemExit(f"archive link escapes Postman/: {raw_name!r}")

    bundle.extractall(path=destination, members=members, filter="data")
PY
}

write_desktop_file() {
  local data_home desktop_dir desktop_file icon_path temp_file

  data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
  [[ "$data_home" == /* ]] || {
    printf 'XDG_DATA_HOME must be an absolute path.\n' >&2
    return 1
  }

  desktop_dir="$data_home/applications"
  desktop_file="$desktop_dir/postman.desktop"
  install -d -m 0755 "$desktop_dir" || return 1
  temp_file="$(mktemp "$desktop_dir/.postman.desktop.XXXXXXXX")" || return 1

  icon_path=""
  for icon_path in \
    "$INSTALL_DIR/app/icons/icon_128x128.png" \
    "$INSTALL_DIR/app/resources/app/assets/icon.png" \
    "$INSTALL_DIR/app/resources/app/assets/icon-128x128.png"; do
    [[ -f "$icon_path" ]] && break
    icon_path=""
  done

  {
    printf '%s\n' '[Desktop Entry]'
    printf '%s\n' 'Type=Application'
    printf '%s\n' 'Version=1.0'
    printf '%s\n' 'Name=Postman'
    printf '%s\n' 'Comment=Postman API Platform'
    printf 'Exec=%s %%U\n' "$COMMAND_LINK"
    printf '%s\n' 'Terminal=false'
    if [[ -n "$icon_path" ]]; then
      printf 'Icon=%s\n' "$icon_path"
    fi
    printf '%s\n' 'Categories=Development;Network;'
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

activate_bundle() {
  local source_dir
  source_dir="$1"
  SYSTEM_PENDING_DIR="/opt/.mint-jelly-postman-new-$$"
  SYSTEM_BACKUP_DIR="/opt/.mint-jelly-postman-old-$$"
  SYSTEM_LINK_BACKUP="/usr/local/bin/.mint-jelly-postman-old-$$"

  if [[ -e "$SYSTEM_PENDING_DIR" || -L "$SYSTEM_PENDING_DIR" \
    || -e "$SYSTEM_BACKUP_DIR" || -L "$SYSTEM_BACKUP_DIR" \
    || -e "$SYSTEM_LINK_BACKUP" || -L "$SYSTEM_LINK_BACKUP" ]]; then
    die "Refusing to overwrite an unexpected Postman transaction path"
  fi
  if [[ -e "$COMMAND_LINK" && ! -L "$COMMAND_LINK" ]]; then
    die "Refusing to overwrite non-symlink command path: $COMMAND_LINK"
  fi

  [[ ! -e "$INSTALL_DIR" && ! -L "$INSTALL_DIR" ]] || SYSTEM_HAD_INSTALL='true'
  [[ ! -e "$COMMAND_LINK" && ! -L "$COMMAND_LINK" ]] || SYSTEM_HAD_LINK='true'
  SYSTEM_TRANSACTION_ACTIVE='true'

  sudo -- install -d -m 0755 "$SYSTEM_PENDING_DIR"
  if ! sudo -- cp -R --no-preserve=ownership -- "$source_dir"/. "$SYSTEM_PENDING_DIR"/; then
    die "Could not stage the Postman application bundle"
  fi

  if [[ ! -f "$SYSTEM_PENDING_DIR/app/Postman" || -L "$SYSTEM_PENDING_DIR/app/Postman" \
    || ! -x "$SYSTEM_PENDING_DIR/app/Postman" ]]; then
    die "The staged Postman executable is not executable"
  fi

  if [[ "$SYSTEM_HAD_INSTALL" == 'true' ]]; then
    sudo -- mv -- "$INSTALL_DIR" "$SYSTEM_BACKUP_DIR"
  fi
  if [[ "$SYSTEM_HAD_LINK" == 'true' ]]; then
    sudo -- mv -- "$COMMAND_LINK" "$SYSTEM_LINK_BACKUP"
  fi

  SYSTEM_NEW_INSTALL_MAY_EXIST='true'
  if ! sudo -- mv -- "$SYSTEM_PENDING_DIR" "$INSTALL_DIR"; then
    die "Could not activate the Postman application bundle"
  fi

  SYSTEM_NEW_LINK_MAY_EXIST='true'
  if ! sudo -- ln -sT -- "$CANONICAL_EXECUTABLE" "$COMMAND_LINK"; then
    die "Could not create the Postman command link"
  fi

  verify_installation >/dev/null \
    || die "The activated Postman installation did not pass verification"

  SYSTEM_TRANSACTION_ACTIVE='false'
  if [[ -e "$SYSTEM_BACKUP_DIR" || -L "$SYSTEM_BACKUP_DIR" ]]; then
    sudo -- rm -rf -- "$SYSTEM_BACKUP_DIR" \
      || warn "Could not remove old Postman backup: $SYSTEM_BACKUP_DIR"
  fi
  if [[ -e "$SYSTEM_LINK_BACKUP" || -L "$SYSTEM_LINK_BACKUP" ]]; then
    sudo -- rm -f -- "$SYSTEM_LINK_BACKUP" \
      || warn "Could not remove old Postman command link: $SYSTEM_LINK_BACKUP"
  fi
}

install_bundle() {
  local architecture archive_file rc source_dir version

  if check_installation; then
    log "$INSTALLER_NAME is already installed; skipping."
    return 0
  else
    rc=$?
    ((rc == 1)) || return "$rc"
  fi

  ((EUID != 0)) || die "Run this installer as the desktop user, not as root"

  require_command cp
  require_command curl
  require_command dpkg
  require_command install
  require_command ln
  require_command mktemp
  require_command mv
  require_command python3
  require_command sudo

  architecture="$(dpkg --print-architecture)"
  [[ "$architecture" == "amd64" ]] || die "$INSTALLER_NAME supports amd64 on Linux Mint; detected $architecture"

  umask 077
  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mint-jelly-postman.XXXXXXXX")"
  archive_file="$TEMP_DIR/postman.tar.gz"

  log "Downloading the official Postman Linux bundle..."
  curl \
    --fail --show-error --silent --location \
    --retry 3 --retry-delay 2 \
    --max-filesize "$MAX_DOWNLOAD_BYTES" \
    --proto '=https' --proto-redir '=https' \
    --output "$archive_file" \
    "$DOWNLOAD_URL"

  warn "Postman does not publish a checksum at this download endpoint; authenticity is limited to HTTPS and archive validation."
  extract_validated_archive "$archive_file" "$TEMP_DIR" \
    || die "Downloaded file is not a safe Postman gzip archive"

  source_dir="$TEMP_DIR/Postman"
  [[ -d "$source_dir" && ! -L "$source_dir" ]] || die "Postman archive has an unexpected top-level layout"
  [[ -f "$source_dir/app/Postman" && ! -L "$source_dir/app/Postman" && -x "$source_dir/app/Postman" ]] \
    || die "Postman archive has no regular app/Postman executable"
  if [[ -e "$source_dir/Postman" || -L "$source_dir/Postman" ]]; then
    [[ -L "$source_dir/Postman" && -x "$source_dir/Postman" \
      && "$source_dir/Postman" -ef "$source_dir/app/Postman" ]] \
      || die "Postman archive has an unsafe top-level launcher"
  fi
  version="$(read_bundle_version "$source_dir" || true)"
  [[ -n "$version" ]] || die "Postman archive has no valid bundle version metadata"
  log "Validated Postman application bundle version $version."

  log "Installing $INSTALLER_NAME..."
  activate_bundle "$source_dir"
  if ! write_desktop_file; then
    warn "Postman was installed, but its per-user desktop launcher could not be written."
  fi
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
    install) install_bundle ;;
    verify) verify_installation ;;
    *)
      usage
      return 64
      ;;
  esac
}

main "$@"
