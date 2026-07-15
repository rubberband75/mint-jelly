#!/usr/bin/env bash
# Remove an installed Mint Jelly application while preserving user data.

set -euo pipefail

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: mint-jelly uninstall [--purge] [--yes]

Removes the Mint Jelly application, launcher, and Bash completion.
Configuration and state are preserved unless --purge is specified.
EOF
}

PURGE='false'
ASSUME_YES='false'
while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge) PURGE='true' ;;
    --yes) ASSUME_YES='true' ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
APP_ROOT="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd -P)"
INSTALL_ROOT="$(dirname -- "$(dirname -- "$APP_ROOT")")"
MARKER_PATH="$INSTALL_ROOT/.mint-jelly-install"
[[ -f "$MARKER_PATH" ]] \
  && grep -qx 'mint-jelly-user-install-v1' "$MARKER_PATH" \
  || die 'This command is not running from a managed Mint Jelly installation.'
[[ "$INSTALL_ROOT" != '/' && "$INSTALL_ROOT" != "$HOME" ]] \
  || die "Unsafe installation directory: $INSTALL_ROOT"
[[ -r "$INSTALL_ROOT/.install-paths" ]] \
  || die 'Installed path metadata is missing.'

command -v flock >/dev/null 2>&1 || die 'Required command not found: flock'
exec 9>"$INSTALL_ROOT/.install.lock"
flock -n 9 || die 'Another Mint Jelly installation is running.'

LAUNCHER_PATH=''
COMPLETION_PATH=''
while IFS='=' read -r key value; do
  case "$key" in
    launcher) LAUNCHER_PATH="$value" ;;
    completion) COMPLETION_PATH="$value" ;;
  esac
done < "$INSTALL_ROOT/.install-paths"
[[ "$LAUNCHER_PATH" == /* && "$COMPLETION_PATH" == /* ]] \
  || die 'Installed path metadata is invalid.'

CONFIG_DIR="${MINT_JELLY_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/mint-jelly}"
STATE_DIR="${MINT_JELLY_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/mint-jelly}"
if [[ "$PURGE" == 'true' ]]; then
  [[ "$CONFIG_DIR" == /* && "$CONFIG_DIR" != '/' && "$CONFIG_DIR" != "$HOME" ]] \
    || die "Unsafe configuration directory: $CONFIG_DIR"
  [[ "$STATE_DIR" == /* && "$STATE_DIR" != '/' && "$STATE_DIR" != "$HOME" ]] \
    || die "Unsafe state directory: $STATE_DIR"
fi

if [[ "$ASSUME_YES" != 'true' ]]; then
  [[ -t 0 && -t 1 ]] \
    || die 'Non-interactive uninstall requires --yes.'
  if [[ "$PURGE" == 'true' ]]; then
    printf 'Remove Mint Jelly and purge its configuration and state? [y/N]: '
  else
    printf 'Remove Mint Jelly from %s? [y/N]: ' "$INSTALL_ROOT"
  fi
  IFS= read -r answer
  case "${answer,,}" in
    y|yes) ;;
    *) die 'Uninstall cancelled.' ;;
  esac
fi

if [[ -L "$LAUNCHER_PATH" ]]; then
  resolved_launcher="$(readlink -f -- "$LAUNCHER_PATH" 2>/dev/null || true)"
  if [[ "$resolved_launcher" == "$INSTALL_ROOT/"* ]]; then
    rm -f -- "$LAUNCHER_PATH"
  else
    warn "Launcher no longer points into this installation; leaving it untouched: $LAUNCHER_PATH"
  fi
elif [[ -e "$LAUNCHER_PATH" ]]; then
  warn "Launcher is not a symlink; leaving it untouched: $LAUNCHER_PATH"
fi

if [[ -f "$COMPLETION_PATH" ]] \
  && cmp -s -- "$APP_ROOT/completions/mint-jelly.bash" "$COMPLETION_PATH"; then
  rm -f -- "$COMPLETION_PATH"
elif [[ -e "$COMPLETION_PATH" ]]; then
  warn "Completion file has changed; leaving it untouched: $COMPLETION_PATH"
fi

cd -- "$HOME"
rm -rf -- "$INSTALL_ROOT"
log 'Mint Jelly was uninstalled.'

if [[ "$PURGE" == 'true' ]]; then
  rm -rf -- "$CONFIG_DIR" "$STATE_DIR"
  log 'Mint Jelly configuration and state were purged.'
else
  log "Configuration preserved at: $CONFIG_DIR"
  log "State preserved at: $STATE_DIR"
fi
