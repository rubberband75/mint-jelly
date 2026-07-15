#!/usr/bin/env bash

# Shared runtime helpers. Entry-point scripts enable strict mode.

MINT_JELLY_CONFIG_DIR="${MINT_JELLY_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/mint-jelly}"
MINT_JELLY_CONFIG_FILE="${MINT_JELLY_CONFIG_FILE:-${MINT_JELLY_CONFIG_DIR}/config.ini}"
MINT_JELLY_STATE_DIR="${MINT_JELLY_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/mint-jelly}"
MINT_JELLY_CACHE_DIR="${MINT_JELLY_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/mint-jelly}"
MINT_JELLY_OPERATION_LOCK_FD=''

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

trim() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

is_interactive() {
  [[ -t 0 && -t 1 ]]
}

validate_safe_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    && [[ "$1" != '.' && "$1" != '..' ]]
}

validate_apt_package_name() {
  # Debian binary package names are lowercase. An optional architecture
  # qualifier is accepted for explicit multiarch selections such as libc6:i386.
  [[ "$1" =~ ^[a-z0-9][a-z0-9+.-]+(:[a-z0-9][a-z0-9-]*)?$ ]]
}

validate_absolute_path() {
  local path="$1"

  [[ "$path" == /* ]] || return 1
  [[ "$path" != '/' ]] || return 1
  [[ "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 1
  [[ ! "$path" =~ (^|/)\.\.?(/|$) ]]
}

remote_shell_quote() {
  local value="$1"

  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] \
    || die 'Cannot pass a value containing a newline to the remote shell.'
  value=${value//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

ensure_config_dir() {
  mkdir -p -- "$MINT_JELLY_CONFIG_DIR"
  chmod 0700 -- "$MINT_JELLY_CONFIG_DIR"
}

require_initialized_config() {
  if [[ ! -f "$MINT_JELLY_CONFIG_FILE" ]]; then
    printf 'First run:\n  mint-jelly config init\n' >&2
    exit 1
  fi
}

local_operation_lock_acquire() {
  ensure_config_dir
  if [[ -n "$MINT_JELLY_OPERATION_LOCK_FD" ]]; then
    return 0
  fi
  require_cmd flock
  exec {MINT_JELLY_OPERATION_LOCK_FD}>"$MINT_JELLY_CONFIG_DIR/operation.lock"
  flock -n "$MINT_JELLY_OPERATION_LOCK_FD" \
    || die 'Another Mint Jelly operation is already running.'
}

local_operation_lock_release() {
  if [[ -n "$MINT_JELLY_OPERATION_LOCK_FD" ]]; then
    flock -u "$MINT_JELLY_OPERATION_LOCK_FD" || true
    eval "exec ${MINT_JELLY_OPERATION_LOCK_FD}>&-"
    MINT_JELLY_OPERATION_LOCK_FD=''
  fi
}
