#!/usr/bin/env bash
# Install Mint Jelly for the current user from a source tree or tagged release.

set -euo pipefail
umask 022

REPOSITORY="${MINT_JELLY_REPOSITORY:-rubberband75/mint-jelly}"
REQUESTED_VERSION="${MINT_JELLY_VERSION:-0.2.0}"
TEMP_DIR=''
STAGE_DIR=''
EXPECTED_VERSION=''

log() {
  printf '%s\n' "$*"
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

usage() {
  cat <<'EOF'
Usage: ./install.sh

Installs Mint Jelly for the current user. When run from the source tree, the
installer copies that tree. When piped from a tagged GitHub URL, it downloads
and verifies the matching release archive.

Optional environment variables:
  MINT_JELLY_INSTALL_DIR  Application installation root
  MINT_JELLY_BIN_DIR      Executable directory (default: ~/.local/bin)
  MINT_JELLY_SOURCE_DIR   Explicit local source directory
  MINT_JELLY_VERSION      Tagged release version for remote installation
  MINT_JELLY_REPOSITORY   GitHub owner/repository for remote installation
EOF
}

cleanup() {
  [[ -z "$STAGE_DIR" || ! -e "$STAGE_DIR" ]] || rm -rf -- "$STAGE_DIR"
  [[ -z "$TEMP_DIR" || ! -e "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"
}

absolute_or_die() {
  local label="$1"
  local path="$2"
  local protected_home="${HOME_REAL:-$HOME}"

  [[ "$path" == /* ]] || die "$label must be an absolute path: $path"
  [[ "$path" != '/' && "$path" != "$protected_home" ]] \
    || die "$label is unsafe: $path"
  [[ "$path" != *$'\n'* && "$path" != *$'\r'* ]] \
    || die "$label contains a newline."
}

normalize_install_path() {
  local label="$1"
  local path="$2"
  local normalized

  absolute_or_die "$label" "$path"
  normalized="$(realpath -m -- "$path")" \
    || die "Could not normalize $label: $path"
  absolute_or_die "$label" "$normalized"
  printf '%s' "$normalized"
}

xdg_data_home() {
  if [[ "${XDG_DATA_HOME:-}" == /* ]]; then
    printf '%s' "$XDG_DATA_HOME"
  else
    printf '%s' "$HOME/.local/share"
  fi
}

find_local_source() {
  local candidate installer_path

  if [[ -n "${MINT_JELLY_SOURCE_DIR+x}" ]]; then
    candidate="$MINT_JELLY_SOURCE_DIR"
    [[ -n "$candidate" ]] \
      || die 'Explicit Mint Jelly source directory cannot be empty.'
    [[ -d "$candidate" ]] \
      || die "Explicit Mint Jelly source directory does not exist: $candidate"
    [[ -f "$candidate/install-manifest.txt" ]] \
      || die "Explicit Mint Jelly source directory is missing install-manifest.txt: $candidate"
    SOURCE_DIR="$(cd -- "$candidate" && pwd -P)" \
      || die "Could not access explicit Mint Jelly source directory: $candidate"
    return 0
  else
    installer_path="$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || true)"
    [[ -n "$installer_path" ]] || return 1
    candidate="$(dirname -- "$installer_path")"
  fi

  [[ -f "$candidate/install-manifest.txt" ]] || return 1
  SOURCE_DIR="$(cd -- "$candidate" && pwd -P)"
}

download_release_source() {
  local tag archive_name archive_url checksum_url checksum_file
  local actual_checksum expected_checksum checksum_name extra
  local -a checksum_lines=()

  require_cmd curl
  require_cmd sha256sum
  require_cmd tar

  REQUESTED_VERSION="${REQUESTED_VERSION#v}"
  [[ "$REQUESTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] \
    || die "Invalid release version: $REQUESTED_VERSION"
  [[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || die "Invalid GitHub repository: $REPOSITORY"
  tag="v$REQUESTED_VERSION"
  EXPECTED_VERSION="$REQUESTED_VERSION"
  archive_name="mint-jelly-$tag.tar.gz"
  archive_url="https://github.com/$REPOSITORY/releases/download/$tag/$archive_name"
  checksum_url="https://github.com/$REPOSITORY/releases/download/$tag/$archive_name.sha256"

  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mint-jelly-install.XXXXXX")"
  checksum_file="$TEMP_DIR/$archive_name.sha256"
  log "Downloading Mint Jelly $REQUESTED_VERSION..."
  curl -fsSL --retry 3 --proto '=https' --proto-redir '=https' \
    --output "$TEMP_DIR/$archive_name" "$archive_url" \
    || die "Could not download release archive: $archive_url"
  curl -fsSL --retry 3 --proto '=https' --proto-redir '=https' \
    --output "$checksum_file" "$checksum_url" \
    || die "Could not download release checksum: $checksum_url"

  mapfile -t checksum_lines < "$checksum_file"
  (( ${#checksum_lines[@]} == 1 )) \
    || die 'Release checksum file must contain exactly one entry.'
  read -r expected_checksum checksum_name extra <<< "${checksum_lines[0]}"
  checksum_name="${checksum_name#\*}"
  [[ "$expected_checksum" =~ ^[A-Fa-f0-9]{64}$ \
    && "$checksum_name" == "$archive_name" && -z "$extra" ]] \
    || die 'Release checksum file has an unexpected format or filename.'
  actual_checksum="$(sha256sum "$TEMP_DIR/$archive_name")"
  actual_checksum="${actual_checksum%% *}"
  [[ "${actual_checksum,,}" == "${expected_checksum,,}" ]] \
    || die 'Release checksum verification failed.'

  mkdir -- "$TEMP_DIR/source"
  tar -xzf "$TEMP_DIR/$archive_name" -C "$TEMP_DIR/source" --strip-components=1
  [[ -f "$TEMP_DIR/source/install-manifest.txt" ]] \
    || die 'Release archive does not contain an installation manifest.'
  SOURCE_DIR="$TEMP_DIR/source"
}

validate_source_tree() {
  local source_version path required_file required_path installer_dir runtime_directory
  local -a fixed_runtime_paths=(
    VERSION
    README.md
    mint-jelly
    backup.sh
    restore.sh
    commands/software.sh
    commands/files.sh
    commands/repos.sh
    commands/system-settings.sh
    commands/apt.sh
    commands/flatpak.sh
    configure.sh
    configure-installers.sh
    configure-apt.sh
    uninstall.sh
    backup.conf.default
    completions/mint-jelly.bash
  )
  local -A manifest_paths=()

  [[ -r "$SOURCE_DIR/VERSION" ]] || die 'Source tree is missing VERSION.'
  source_version="$(<"$SOURCE_DIR/VERSION")"
  [[ "$source_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] \
    || die "Invalid VERSION value: $source_version"
  VERSION="$source_version"

  while IFS= read -r path || [[ -n "$path" ]]; do
    [[ -z "$path" || "$path" == \#* ]] && continue
    [[ "$path" != /* && ! "$path" =~ (^|/)\.\.?(/|$) ]] \
      || die "Unsafe installation manifest path: $path"
    case "$path" in
      VERSION|README.md|mint-jelly|backup.sh|restore.sh|configure.sh|configure-installers.sh|configure-apt.sh|uninstall.sh|backup.conf.default|completions/mint-jelly.bash)
        ;;
      commands/*.sh)
        [[ "$path" =~ ^commands/[A-Za-z0-9][A-Za-z0-9._-]*\.sh$ ]] \
          || die "Installation manifest contains a non-runtime path: $path"
        ;;
      lib/*.sh)
        [[ "$path" =~ ^lib/[A-Za-z0-9][A-Za-z0-9._-]*\.sh$ ]] \
          || die "Installation manifest contains a non-runtime path: $path"
        ;;
      installers/*/installer.conf|installers/*/run.sh)
        [[ "$path" =~ ^installers/[A-Za-z0-9][A-Za-z0-9._-]*/(installer\.conf|run\.sh)$ ]] \
          || die "Installation manifest contains a non-runtime path: $path"
        [[ -d "$SOURCE_DIR/${path%/*}" && ! -L "$SOURCE_DIR/${path%/*}" ]] \
          || die "Installer module directory is missing or unsafe: ${path%/*}"
        ;;
      *)
        die "Installation manifest contains a non-runtime path: $path"
        ;;
    esac
    [[ -z "${manifest_paths[$path]+set}" ]] \
      || die "Installation manifest lists a path more than once: $path"
    manifest_paths["$path"]=1
    [[ -f "$SOURCE_DIR/$path" && ! -L "$SOURCE_DIR/$path" ]] \
      || die "Installation manifest file is missing or is a symbolic link: $path"
  done < "$SOURCE_DIR/install-manifest.txt"

  for required_path in "${fixed_runtime_paths[@]}"; do
    [[ -n "${manifest_paths[$required_path]+set}" ]] \
      || die "Required runtime file is missing from install-manifest.txt: $required_path"
  done

  for runtime_directory in commands lib installers; do
    [[ -d "$SOURCE_DIR/$runtime_directory" \
      && ! -L "$SOURCE_DIR/$runtime_directory" ]] \
      || die "Source tree has a missing or unsafe runtime directory: $runtime_directory"
  done
  while IFS= read -r -d '' required_file; do
    required_path="${required_file#"$SOURCE_DIR/"}"
    [[ -n "${manifest_paths[$required_path]+set}" ]] \
      || die "Runtime library is missing from install-manifest.txt: $required_path"
  done < <(find "$SOURCE_DIR/lib" -mindepth 1 -maxdepth 1 -type f -name '*.sh' -print0)
  while IFS= read -r -d '' required_file; do
    required_path="${required_file#"$SOURCE_DIR/"}"
    [[ -n "${manifest_paths[$required_path]+set}" ]] \
      || die "Runtime command is missing from install-manifest.txt: $required_path"
  done < <(find "$SOURCE_DIR/commands" -mindepth 1 -maxdepth 1 -type f -name '*.sh' -print0)
  while IFS= read -r -d '' installer_dir; do
    for required_path in installer.conf run.sh; do
      required_file="$installer_dir/$required_path"
      [[ -f "$required_file" ]] \
        || die "Installer module '${installer_dir##*/}' is missing $required_path."
      required_path="${required_file#"$SOURCE_DIR/"}"
      [[ -n "${manifest_paths[$required_path]+set}" ]] \
        || die "Installer runtime file is missing from install-manifest.txt: $required_path"
    done
  done < <(find "$SOURCE_DIR/installers" -mindepth 1 -maxdepth 1 -type d -print0)

  [[ -z "$EXPECTED_VERSION" || "$VERSION" == "$EXPECTED_VERSION" ]] \
    || die "Release archive version is $VERSION; expected $EXPECTED_VERSION."
}

launcher_is_owned() {
  local resolved target

  [[ -L "$LAUNCHER_PATH" ]] || return 1
  target="$(readlink -- "$LAUNCHER_PATH")"
  if [[ "$target" == /* ]]; then
    resolved="$(readlink -m -- "$target")"
  else
    resolved="$(readlink -m -- "$BIN_DIR/$target")"
  fi
  [[ "$resolved" == "$INSTALL_ROOT/"* ]]
}

runtime_path_mode() {
  case "$1" in
    mint-jelly|backup.sh|restore.sh|configure.sh|configure-installers.sh|configure-apt.sh|uninstall.sh|commands/*.sh|installers/*/run.sh)
      printf '0755'
      ;;
    *)
      printf '0644'
      ;;
  esac
}

copy_runtime_files() {
  local path destination mode

  install -d -m 0755 -- "$STAGE_DIR"
  while IFS= read -r path || [[ -n "$path" ]]; do
    [[ -z "$path" || "$path" == \#* ]] && continue
    destination="$STAGE_DIR/$path"
    install -d -m 0755 -- "$(dirname -- "$destination")"
    mode="$(runtime_path_mode "$path")"
    install -m "$mode" -- "$SOURCE_DIR/$path" "$destination"
  done < "$SOURCE_DIR/install-manifest.txt"
}

validate_staged_version() {
  local script path expected_mode

  while IFS= read -r -d '' script; do
    bash -n -- "$script"
  done < <(find "$STAGE_DIR" -type f \( -name '*.sh' -o -name 'mint-jelly' \) -print0)
  while IFS= read -r path || [[ -n "$path" ]]; do
    [[ -z "$path" || "$path" == \#* ]] && continue
    expected_mode="$(runtime_path_mode "$path")"
    if [[ "$expected_mode" == '0755' ]]; then
      [[ -x "$STAGE_DIR/$path" ]] \
        || die "Staged runtime command is not executable: $path"
    else
      [[ ! -x "$STAGE_DIR/$path" ]] \
        || die "Staged runtime data unexpectedly became executable: $path"
    fi
  done < "$SOURCE_DIR/install-manifest.txt"
  "$STAGE_DIR/mint-jelly" version >/dev/null
}

trap cleanup EXIT

case "${1-}" in
  '') ;;
  -h|--help)
    [[ $# -eq 1 ]] || die '--help does not accept additional arguments.'
    usage
    exit 0
    ;;
  *) die "Unknown argument: $1" ;;
esac

(( BASH_VERSINFO[0] >= 4 )) || die 'Mint Jelly requires Bash 4 or newer.'
require_cmd bash
require_cmd cmp
require_cmd dconf
require_cmd find
require_cmd flock
require_cmd hostname
require_cmd install
require_cmd pgrep
require_cmd readlink
require_cmd realpath
require_cmd rsync
require_cmd sed
require_cmd ssh

if ! find_local_source; then
  download_release_source
fi
validate_source_tree

DATA_HOME="$(xdg_data_home)"
HOME_REAL="$(realpath -m -- "$HOME")" \
  || die "Could not normalize the home directory: $HOME"
[[ "$HOME_REAL" == /* && "$HOME_REAL" != '/' ]] \
  || die "Home directory is unsafe: $HOME_REAL"
INSTALL_ROOT="$(normalize_install_path 'Installation directory' \
  "${MINT_JELLY_INSTALL_DIR:-$DATA_HOME/mint-jelly}")"
BIN_DIR="$(normalize_install_path 'Executable directory' \
  "${MINT_JELLY_BIN_DIR:-$HOME/.local/bin}")"
COMPLETION_USER_DIR="${BASH_COMPLETION_USER_DIR:-$DATA_HOME/bash-completion}"
COMPLETION_USER_DIR="${COMPLETION_USER_DIR%%:*}"
[[ "$COMPLETION_USER_DIR" == /* ]] \
  || COMPLETION_USER_DIR="$DATA_HOME/bash-completion"
COMPLETION_DIR="$(normalize_install_path 'Completion directory' \
  "$COMPLETION_USER_DIR/completions")"
LAUNCHER_PATH="$BIN_DIR/mint-jelly"
COMPLETION_PATH="$COMPLETION_DIR/mint-jelly.bash"
MARKER_PATH="$INSTALL_ROOT/.mint-jelly-install"
WAS_INSTALLED='false'

if [[ -e "$INSTALL_ROOT" ]]; then
  if [[ -f "$MARKER_PATH" ]] && grep -qx 'mint-jelly-user-install-v1' "$MARKER_PATH"; then
    WAS_INSTALLED='true'
  elif find "$INSTALL_ROOT" -mindepth 1 -print -quit | grep -q .; then
    die "Installation directory exists but is not owned by Mint Jelly: $INSTALL_ROOT"
  fi
fi

if [[ -e "$LAUNCHER_PATH" || -L "$LAUNCHER_PATH" ]]; then
  launcher_is_owned \
    || die "Refusing to replace an unrelated command: $LAUNCHER_PATH"
fi
if [[ "$WAS_INSTALLED" == 'false' && -e "$COMPLETION_PATH" ]] \
  && ! cmp -s -- "$SOURCE_DIR/completions/mint-jelly.bash" "$COMPLETION_PATH"; then
  die "Refusing to replace an unrelated completion file: $COMPLETION_PATH"
fi

install -d -m 0755 -- "$INSTALL_ROOT" "$INSTALL_ROOT/versions" "$BIN_DIR" "$COMPLETION_DIR"
printf 'mint-jelly-user-install-v1\n' > "$MARKER_PATH"
chmod 0644 -- "$MARKER_PATH"
exec 9>"$INSTALL_ROOT/.install.lock"
flock -n 9 || die 'Another Mint Jelly installation is already running.'

PREVIOUS_DEPLOYMENT=''
if [[ -L "$INSTALL_ROOT/current" ]]; then
  previous_link="$(readlink -- "$INSTALL_ROOT/current")"
  if [[ "$previous_link" == versions/* \
    && -d "$INSTALL_ROOT/$previous_link" \
    && ! -L "$INSTALL_ROOT/$previous_link" ]]; then
    PREVIOUS_DEPLOYMENT="$INSTALL_ROOT/$previous_link"
  fi
fi

DEPLOYMENT_NAME="$VERSION-$(date -u '+%Y%m%dT%H%M%S%NZ')-$$"
TARGET_DIR="$INSTALL_ROOT/versions/$DEPLOYMENT_NAME"
STAGE_DIR="$INSTALL_ROOT/versions/.$DEPLOYMENT_NAME.tmp"
rm -rf -- "$STAGE_DIR"
copy_runtime_files
validate_staged_version

mv -- "$STAGE_DIR" "$TARGET_DIR" \
  || die "Could not stage Mint Jelly $VERSION."
STAGE_DIR=''

rm -f -- "$INSTALL_ROOT/.current.$$" "$BIN_DIR/.mint-jelly.$$"
# The application remains available throughout an update: a fully validated
# deployment is created first, then this symlink is replaced atomically.
ln -s -- "versions/$DEPLOYMENT_NAME" "$INSTALL_ROOT/.current.$$"
mv -Tf -- "$INSTALL_ROOT/.current.$$" "$INSTALL_ROOT/current"
install -m 0644 -- "$TARGET_DIR/completions/mint-jelly.bash" "$COMPLETION_PATH"
ln -s -- "$INSTALL_ROOT/current/mint-jelly" "$BIN_DIR/.mint-jelly.$$"
mv -Tf -- "$BIN_DIR/.mint-jelly.$$" "$LAUNCHER_PATH"

# Keep the active deployment and one known-good predecessor for a manual
# rollback while preventing repeated installs from growing without bound.
for deployment in "$INSTALL_ROOT/versions/"*; do
  [[ -d "$deployment" && ! -L "$deployment" ]] || continue
  [[ "$deployment" == "$TARGET_DIR" || "$deployment" == "$PREVIOUS_DEPLOYMENT" ]] \
    && continue
  rm -rf -- "$deployment"
done

{
  printf 'launcher=%s\n' "$LAUNCHER_PATH"
  printf 'completion=%s\n' "$COMPLETION_PATH"
} > "$INSTALL_ROOT/.install-paths"
chmod 0644 -- "$INSTALL_ROOT/.install-paths"

"$LAUNCHER_PATH" version >/dev/null
log "Mint Jelly $VERSION installed successfully."
log "  Command:     $LAUNCHER_PATH"
log "  Application: $TARGET_DIR"
log "  Completion: $COMPLETION_PATH"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    log ''
    log "$BIN_DIR is not active in this shell. Run:"
    log '  exec bash -l'
    ;;
esac
