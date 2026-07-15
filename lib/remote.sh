#!/usr/bin/env bash

ACTIVE_REMOTE=''
ACTIVE_REMOTE_TYPE=''
ACTIVE_HOST_BASE=''
SSH_TARGET=''
SSH_CONTROL_PATH=''
SSH_PORT=''
SSH_OPTIONS=()
REMOTE_LOCK_MODE=''
REMOTE_LOCK_FD=''
REMOTE_LOCK_PID=''
REMOTE_LOCK_INPUT_FD=''
REMOTE_LOCK_OUTPUT_FD=''
REMOTE_LOCK_HEARTBEAT_TIMEOUT=''

remote_exec_script() {
  local script="$1"
  shift
  local command='sh -s --' argument

  for argument in "$@"; do
    command+=" $(remote_shell_quote "$argument")"
  done
  printf '%s\n' "$script" | ssh "${SSH_OPTIONS[@]}" "$SSH_TARGET" "$command"
}

_remote_build_shell_command() {
  local script="$1"
  shift
  local command argument

  command="sh -c $(remote_shell_quote "$script") sh"
  for argument in "$@"; do
    command+=" $(remote_shell_quote "$argument")"
  done
  printf '%s' "$command"
}

_remote_lock_reset() {
  REMOTE_LOCK_MODE=''
  REMOTE_LOCK_FD=''
  REMOTE_LOCK_PID=''
  REMOTE_LOCK_INPUT_FD=''
  REMOTE_LOCK_OUTPUT_FD=''
  REMOTE_LOCK_HEARTBEAT_TIMEOUT=''
  unset MINT_JELLY_LOCK_COPROC MINT_JELLY_LOCK_COPROC_PID 2>/dev/null || true
}

_remote_lock_abort_ssh_session() {
  if [[ -n "$REMOTE_LOCK_INPUT_FD" \
    && ( -e "/proc/$BASHPID/fd/$REMOTE_LOCK_INPUT_FD" \
      || -L "/proc/$BASHPID/fd/$REMOTE_LOCK_INPUT_FD" ) ]]; then
    exec {REMOTE_LOCK_INPUT_FD}>&- || true
  fi
  if [[ -n "$REMOTE_LOCK_PID" ]]; then
    kill -TERM "$REMOTE_LOCK_PID" 2>/dev/null || true
    kill -KILL "$REMOTE_LOCK_PID" 2>/dev/null || true
    wait "$REMOTE_LOCK_PID" 2>/dev/null || true
  fi
  if [[ -n "$REMOTE_LOCK_OUTPUT_FD" \
    && ( -e "/proc/$BASHPID/fd/$REMOTE_LOCK_OUTPUT_FD" \
      || -L "/proc/$BASHPID/fd/$REMOTE_LOCK_OUTPUT_FD" ) ]]; then
    exec {REMOTE_LOCK_OUTPUT_FD}<&- || true
  fi
  _remote_lock_reset
}

_remote_lock_die_lost() {
  local detail="$1"

  _remote_lock_abort_ssh_session
  die "The SSH remote lock was lost; refusing to continue without synchronization ($detail)."
}

remote_lock_verify() {
  local response=''

  [[ -n "$REMOTE_LOCK_MODE" ]] \
    || die 'No remote lock is currently held.'
  [[ "$ACTIVE_REMOTE_TYPE" == 'ssh' ]] || return 0
  [[ "$REMOTE_LOCK_PID" =~ ^[1-9][0-9]*$ ]] \
    && kill -0 "$REMOTE_LOCK_PID" 2>/dev/null \
    || _remote_lock_die_lost 'the lock-holder process exited'
  [[ -n "$REMOTE_LOCK_INPUT_FD" \
    && ( -e "/proc/$BASHPID/fd/$REMOTE_LOCK_INPUT_FD" \
      || -L "/proc/$BASHPID/fd/$REMOTE_LOCK_INPUT_FD" ) ]] \
    || _remote_lock_die_lost 'the lock request channel closed'
  [[ -n "$REMOTE_LOCK_OUTPUT_FD" \
    && ( -e "/proc/$BASHPID/fd/$REMOTE_LOCK_OUTPUT_FD" \
      || -L "/proc/$BASHPID/fd/$REMOTE_LOCK_OUTPUT_FD" ) ]] \
    || _remote_lock_die_lost 'the lock response channel closed'

  if ! printf 'PING\n' >&"$REMOTE_LOCK_INPUT_FD"; then
    _remote_lock_die_lost 'the lock request channel failed'
  fi
  if ! IFS= read -r -t "$REMOTE_LOCK_HEARTBEAT_TIMEOUT" response \
    <&"$REMOTE_LOCK_OUTPUT_FD"; then
    _remote_lock_die_lost 'the lock holder did not answer its heartbeat'
  fi
  [[ "$response" == 'ALIVE' ]] \
    || _remote_lock_die_lost 'the lock holder returned an invalid heartbeat'
}

remote_lock_acquire() {
  local mode="$1"
  local metadata_directory="${ACTIVE_HOST_BASE}/.mint-jelly"
  local lock_file="${metadata_directory}/operation.lock"
  local timeout="${MINT_JELLY_REMOTE_LOCK_TIMEOUT:-30}"
  local create_directory='false'
  local flag command acknowledgement status
  local coproc_input_fd coproc_output_fd
  local script

  [[ "$mode" == 'shared' || "$mode" == 'exclusive' ]] \
    || die "Invalid remote lock mode: $mode"
  [[ -z "$REMOTE_LOCK_MODE" ]] \
    || die "A $REMOTE_LOCK_MODE remote lock is already held."
  [[ "$timeout" =~ ^[1-9][0-9]*$ ]] && (( 10#$timeout <= 3600 )) \
    || die 'MINT_JELLY_REMOTE_LOCK_TIMEOUT must be between 1 and 3600 seconds.'
  [[ "$mode" != 'exclusive' ]] || create_directory='true'

  if [[ "$ACTIVE_REMOTE_TYPE" == 'local' ]]; then
    require_cmd flock
    [[ -d "$ACTIVE_HOST_BASE" && ! -L "$ACTIVE_HOST_BASE" ]] \
      || die "Remote host backup directory is missing or unsafe: $ACTIVE_HOST_BASE"
    if [[ "$create_directory" == 'true' ]]; then
      [[ ! -e "$metadata_directory" && ! -L "$metadata_directory" \
        || ( -d "$metadata_directory" && ! -L "$metadata_directory" ) ]] \
        || die "Refusing unsafe recovery metadata directory: $metadata_directory"
      mkdir -p -- "$metadata_directory"
      chmod 0700 -- "$metadata_directory"
    else
      [[ -d "$metadata_directory" && ! -L "$metadata_directory" ]] \
        || die "Recovery metadata directory is missing or unsafe: $metadata_directory"
    fi
    [[ ( ! -e "$lock_file" && ! -L "$lock_file" ) \
      || ( -f "$lock_file" && ! -L "$lock_file" ) ]] \
      || die "Refusing unsafe remote lock file: $lock_file"
    exec {REMOTE_LOCK_FD}>> "$lock_file" \
      || die "Could not open remote lock file: $lock_file"
    chmod 0600 -- "$lock_file" || {
      exec {REMOTE_LOCK_FD}>&-
      REMOTE_LOCK_FD=''
      die "Could not secure remote lock file: $lock_file"
    }
    flag='-s'
    [[ "$mode" != 'exclusive' ]] || flag='-x'
    if ! flock "$flag" -w "$timeout" "$REMOTE_LOCK_FD"; then
      exec {REMOTE_LOCK_FD}>&-
      REMOTE_LOCK_FD=''
      die "Timed out waiting for the $mode remote lock after $timeout seconds."
    fi
    REMOTE_LOCK_MODE="$mode"
    return 0
  fi

  script='set -eu; host_base=$1; metadata_directory=$2; lock_file=$3; lock_mode=$4; timeout=$5; create_directory=$6; umask 077; if ! command -v flock >/dev/null 2>&1; then printf "ERROR:flock is unavailable on the remote host\n"; exit 69; fi; [ -d "$host_base" ] && [ ! -L "$host_base" ] || { printf "ERROR:remote host backup directory is missing or unsafe\n"; exit 66; }; if [ "$create_directory" = true ]; then [ ! -e "$metadata_directory" ] && [ ! -L "$metadata_directory" ] || { [ -d "$metadata_directory" ] && [ ! -L "$metadata_directory" ]; }; mkdir -p -- "$metadata_directory"; chmod 700 -- "$metadata_directory"; else [ -d "$metadata_directory" ] && [ ! -L "$metadata_directory" ] || { printf "ERROR:recovery metadata directory is missing or unsafe\n"; exit 66; }; fi; [ ! -e "$lock_file" ] && [ ! -L "$lock_file" ] || { [ -f "$lock_file" ] && [ ! -L "$lock_file" ]; } || { printf "ERROR:remote lock file is unsafe\n"; exit 66; }; exec 9>> "$lock_file"; chmod 600 -- "$lock_file"; flag=-s; [ "$lock_mode" != exclusive ] || flag=-x; if ! flock "$flag" -w "$timeout" 9; then printf "ERROR:timed out waiting for the %s remote lock after %s seconds\n" "$lock_mode" "$timeout"; exit 75; fi; printf "LOCKED\n"; while IFS= read -r request; do [ "$request" = PING ] || { printf "ERROR:invalid lock heartbeat\n"; exit 76; }; printf "ALIVE\n"; done'
  command="$(_remote_build_shell_command \
    "$script" "$ACTIVE_HOST_BASE" "$metadata_directory" "$lock_file" \
    "$mode" "$timeout" "$create_directory")"

  coproc MINT_JELLY_LOCK_COPROC {
    ssh "${SSH_OPTIONS[@]}" "$SSH_TARGET" "$command"
  }
  REMOTE_LOCK_PID="$MINT_JELLY_LOCK_COPROC_PID"
  coproc_output_fd="${MINT_JELLY_LOCK_COPROC[0]}"
  coproc_input_fd="${MINT_JELLY_LOCK_COPROC[1]}"
  if ! exec {REMOTE_LOCK_OUTPUT_FD}<&"$coproc_output_fd"; then
    _remote_lock_abort_ssh_session
    die 'Could not preserve the SSH remote lock response channel.'
  fi
  if ! exec {REMOTE_LOCK_INPUT_FD}>&"$coproc_input_fd"; then
    _remote_lock_abort_ssh_session
    die 'Could not preserve the SSH remote lock request channel.'
  fi
  exec {coproc_output_fd}<&-
  exec {coproc_input_fd}>&-
  acknowledgement=''
  if ! IFS= read -r acknowledgement <&"$REMOTE_LOCK_OUTPUT_FD"; then
    exec {REMOTE_LOCK_INPUT_FD}>&- || true
    status=0
    wait "$REMOTE_LOCK_PID" || status=$?
    exec {REMOTE_LOCK_OUTPUT_FD}<&- || true
    _remote_lock_reset
    die "Could not acquire the $mode remote lock (remote lock process exited with status $status)."
  fi
  if [[ "$acknowledgement" != 'LOCKED' ]]; then
    exec {REMOTE_LOCK_INPUT_FD}>&- || true
    wait "$REMOTE_LOCK_PID" 2>/dev/null || true
    exec {REMOTE_LOCK_OUTPUT_FD}<&- || true
    _remote_lock_reset
    if [[ "$acknowledgement" == ERROR:* ]]; then
      die "${acknowledgement#ERROR:}"
    fi
    die "Unexpected response while acquiring the $mode remote lock."
  fi
  REMOTE_LOCK_MODE="$mode"
  REMOTE_LOCK_HEARTBEAT_TIMEOUT="$timeout"
}

remote_lock_release() {
  local status=0

  [[ -n "$REMOTE_LOCK_MODE" ]] || return 0
  if [[ "$ACTIVE_REMOTE_TYPE" == 'local' ]]; then
    if [[ -n "$REMOTE_LOCK_FD" ]]; then
      flock -u "$REMOTE_LOCK_FD" || status=$?
      exec {REMOTE_LOCK_FD}>&- || status=$?
    fi
    _remote_lock_reset
    return "$status"
  fi

  [[ -z "$REMOTE_LOCK_INPUT_FD" ]] \
    || exec {REMOTE_LOCK_INPUT_FD}>&- || status=$?
  if [[ -n "$REMOTE_LOCK_PID" ]]; then
    wait "$REMOTE_LOCK_PID" || status=$?
  fi
  [[ -z "$REMOTE_LOCK_OUTPUT_FD" ]] \
    || exec {REMOTE_LOCK_OUTPUT_FD}<&- || status=$?
  _remote_lock_reset
  return "$status"
}

remote_require_lock() {
  local required="$1"

  case "$required:$REMOTE_LOCK_MODE" in
    shared:shared|shared:exclusive|exclusive:exclusive) remote_lock_verify ;;
    exclusive:*) die 'This remote operation requires an exclusive remote lock.' ;;
    shared:*) die 'This remote operation requires a shared or exclusive remote lock.' ;;
    *) die "Invalid required remote lock mode: $required" ;;
  esac
}

remote_assert_mirror_path() {
  local path="$1"
  local path_kind="$2"
  local relative current component rest is_final

  [[ "$path_kind" == 'directory' || "$path_kind" == 'leaf' ]] \
    || die "Invalid mirror path kind: $path_kind"
  validate_absolute_path "$path" \
    || die "Refusing an unsafe mirror path: $path"
  [[ "$path" == "$ACTIVE_HOST_BASE" \
    || "$path" == "$ACTIVE_HOST_BASE/"* ]] \
    || die "Refusing a path outside the active backup mirror: $path"
  remote_require_lock shared

  if [[ "$ACTIVE_REMOTE_TYPE" == 'ssh' ]]; then
    remote_exec_script '
set -eu
host_base=$1
path=$2
path_kind=$3

[ -d "$host_base" ] && [ ! -L "$host_base" ] || {
  printf "Unsafe backup-mirror host directory: %s\n" "$host_base" >&2
  exit 66
}
case "$path" in
  "$host_base"|"$host_base"/*) ;;
  *)
    printf "Path is outside the active backup mirror: %s\n" "$path" >&2
    exit 66
    ;;
esac
[ "$path" != "$host_base" ] || exit 0

rest=${path#"$host_base"/}
current=$host_base
while [ -n "$rest" ]; do
  case "$rest" in
    */*)
      component=${rest%%/*}
      rest=${rest#*/}
      is_final=false
      ;;
    *)
      component=$rest
      rest=
      is_final=true
      ;;
  esac
  [ -n "$component" ] || continue
  current=$current/$component
  if [ -L "$current" ] \
    && { [ "$path_kind" = directory ] || [ "$is_final" = false ]; }; then
    printf "Unsafe symbolic-link mirror component: %s\n" "$current" >&2
    exit 66
  fi
  if [ -e "$current" ] && [ ! -d "$current" ]; then
    if [ "$path_kind" = leaf ] && [ "$is_final" = true ]; then
      :
    else
      printf "Non-directory mirror path component: %s\n" "$current" >&2
      exit 66
    fi
  fi
done
' "$ACTIVE_HOST_BASE" "$path" "$path_kind" \
      || die "Mirror path is missing or unsafe: $path"
    return 0
  fi

  [[ -d "$ACTIVE_HOST_BASE" && ! -L "$ACTIVE_HOST_BASE" ]] \
    || die "Unsafe backup-mirror host directory: $ACTIVE_HOST_BASE"
  [[ "$path" != "$ACTIVE_HOST_BASE" ]] || return 0
  relative="${path:${#ACTIVE_HOST_BASE}+1}"
  current="$ACTIVE_HOST_BASE"
  rest="$relative"
  while [[ -n "$rest" ]]; do
    if [[ "$rest" == */* ]]; then
      component="${rest%%/*}"
      rest="${rest#*/}"
      is_final='false'
    else
      component="$rest"
      rest=''
      is_final='true'
    fi
    [[ -n "$component" ]] || continue
    current="${current}/${component}"
    if [[ -L "$current" \
      && ( "$path_kind" == 'directory' || "$is_final" == 'false' ) ]]; then
      die "Unsafe symbolic-link mirror component: $current"
    fi
    if [[ -e "$current" && ! -d "$current" ]]; then
      if [[ "$path_kind" != 'leaf' || "$is_final" != 'true' ]]; then
        die "Non-directory mirror path component: $current"
      fi
    fi
  done
}

remote_open() {
  local name="$1"
  local machine_name="$2"
  local access_mode="${3:-write}"
  local root_path

  config_validate_remote "$name"
  validate_safe_name "$machine_name" \
    || die "Unsafe local hostname: $machine_name"
  [[ "$access_mode" == 'read' || "$access_mode" == 'write' ]] \
    || die "Invalid remote access mode: $access_mode"

  ACTIVE_REMOTE="$name"
  ACTIVE_REMOTE_TYPE="${REMOTE_TYPE[$name]}"
  root_path="${REMOTE_ROOT_PATH[$name]%/}"
  ACTIVE_HOST_BASE="${root_path}/${machine_name}"

  if [[ "$ACTIVE_REMOTE_TYPE" == 'local' ]]; then
    if [[ "$access_mode" == 'read' ]]; then
      [[ -d "$ACTIVE_HOST_BASE" && ! -L "$ACTIVE_HOST_BASE" \
        && -r "$ACTIVE_HOST_BASE" && -x "$ACTIVE_HOST_BASE" ]] \
        || die "Local backup directory is not readable: $ACTIVE_HOST_BASE"
    else
      [[ ! -L "$ACTIVE_HOST_BASE" \
        && ( ! -e "$ACTIVE_HOST_BASE" || -d "$ACTIVE_HOST_BASE" ) ]] \
        || die "Refusing unsafe local backup directory: $ACTIVE_HOST_BASE"
      mkdir -p -- "$ACTIVE_HOST_BASE"
      chmod 0700 -- "$ACTIVE_HOST_BASE"
      [[ -d "$ACTIVE_HOST_BASE" && ! -L "$ACTIVE_HOST_BASE" \
        && -w "$ACTIVE_HOST_BASE" && -x "$ACTIVE_HOST_BASE" ]] \
        || die "Local backup directory is not writable: $ACTIVE_HOST_BASE"
    fi
    return 0
  fi

  require_cmd ssh
  SSH_TARGET="${REMOTE_USERNAME[$name]}@${REMOTE_HOST[$name]}"
  SSH_PORT="${REMOTE_PORT[$name]}"
  SSH_CONTROL_PATH="/tmp/mint-jelly-ssh-${UID}-$$.sock"
  rm -f -- "$SSH_CONTROL_PATH"
  SSH_OPTIONS=(
    -o ControlMaster=auto
    -o ControlPersist=120
    -o "ControlPath=$SSH_CONTROL_PATH"
    -o ConnectTimeout=10
    -p "$SSH_PORT"
  )

  log "Connecting to SSH remote '$name' ($SSH_TARGET)..."
  if ! ssh "${SSH_OPTIONS[@]}" "$SSH_TARGET" true; then
    die "Could not connect to SSH remote '$name'."
  fi

  if [[ "$access_mode" == 'read' ]]; then
    remote_exec_script '
set -eu
source_directory=$1
[ -d "$source_directory" ] && [ ! -L "$source_directory" ] \
  && [ -r "$source_directory" ] && [ -x "$source_directory" ]
' "$ACTIVE_HOST_BASE" \
      || die "Remote backup directory is not readable: $ACTIVE_HOST_BASE"
    return 0
  fi

  remote_exec_script '
set -eu
destination=$1
umask 077
[ ! -L "$destination" ] \
  && { [ ! -e "$destination" ] || [ -d "$destination" ]; } || exit 66
mkdir -p -- "$destination"
chmod 700 -- "$destination"
[ -d "$destination" ] && [ ! -L "$destination" ] || exit 66
probe="${destination}/.mint-jelly-write-test-$$"
: > "$probe"
rm -f -- "$probe"
' "$ACTIVE_HOST_BASE" || die "Remote backup directory is not writable: $ACTIVE_HOST_BASE"
}

remote_close() {
  if ! remote_lock_release; then
    warn 'The remote lock session did not close cleanly.'
  fi
  if [[ -n "$SSH_CONTROL_PATH" && -S "$SSH_CONTROL_PATH" ]]; then
    ssh "${SSH_OPTIONS[@]}" -O exit "$SSH_TARGET" >/dev/null 2>&1 || true
  fi
  [[ -n "$SSH_CONTROL_PATH" ]] && rm -f -- "$SSH_CONTROL_PATH"
  SSH_CONTROL_PATH=''
}

remote_ensure_directory() {
  local directory="$1"

  remote_require_lock exclusive
  remote_assert_mirror_path "$directory" directory
  if [[ "$ACTIVE_REMOTE_TYPE" == 'local' ]]; then
    mkdir -p -- "$directory" || return 1
    remote_assert_mirror_path "$directory" directory
    return
  fi

  remote_exec_script '
set -eu
directory=$1
umask 077
mkdir -p -- "$directory"
' "$directory" || return 1
  remote_assert_mirror_path "$directory" directory
}

remote_rsync() {
  local source="$1"
  local destination="$2"
  local history_destination="$3"
  local dry_run="$4"
  local destination_argument
  local -a options=(
    --archive
    --human-readable
    --itemize-changes
    --delete-delay
    --backup
    "--backup-dir=$history_destination"
  )

  remote_require_lock exclusive
  require_cmd rsync
  [[ "$dry_run" == 'true' ]] && options+=(--dry-run)
  remote_assert_mirror_path "${destination%/}" directory
  remote_assert_mirror_path "${history_destination%/}" directory

  if [[ "$ACTIVE_REMOTE_TYPE" == 'ssh' ]]; then
    options+=(--protect-args -e "ssh -p $SSH_PORT -o ControlPath=$SSH_CONTROL_PATH")
    destination_argument="${SSH_TARGET}:${destination}"
  else
    destination_argument="$destination"
  fi

  rsync "${options[@]}" -- "$source" "$destination_argument" || return 1
  remote_assert_mirror_path "${destination%/}" directory
  remote_assert_mirror_path "${history_destination%/}" directory
}

remote_manifest_filename() {
  case "$1" in
    files) printf 'files.manifest' ;;
    software) printf 'software.manifest' ;;
    apt) printf 'apt.manifest' ;;
    flatpak) printf 'flatpak.manifest' ;;
    *) die "Unsupported remote manifest kind: $1" ;;
  esac
}

remote_write_manifest() {
  local kind="$1"
  local local_manifest="$2"
  local metadata_directory="${ACTIVE_HOST_BASE}/.mint-jelly"
  local filename manifest
  local temporary byte_count staged_count command
  local max_bytes="${3:-1048576}"
  local max_plus_one=$((max_bytes + 1))
  local script

  filename="$(remote_manifest_filename "$kind")"
  manifest="${metadata_directory}/${filename}"

  remote_require_lock exclusive
  remote_assert_mirror_path "$metadata_directory" directory
  [[ -f "$local_manifest" && ! -L "$local_manifest" ]] \
    || die "Manifest is not a safe regular file: $local_manifest"
  require_cmd wc
  byte_count="$(wc -c < "$local_manifest")" \
    || die "Could not measure recovery manifest: $local_manifest"
  byte_count="$(trim "$byte_count")"
  [[ "$byte_count" =~ ^[1-9][0-9]*$ ]] \
    && (( 10#$byte_count <= max_bytes )) \
    || die "Manifest must contain between 1 and $max_bytes bytes."

  if [[ "$ACTIVE_REMOTE_TYPE" == 'ssh' ]]; then
    script='set -eu; metadata_directory=$1; manifest=$2; max_bytes=$3; max_plus_one=$4; expected_bytes=$5; umask 077; [ -d "$metadata_directory" ] && [ ! -L "$metadata_directory" ]; [ ! -e "$manifest" ] && [ ! -L "$manifest" ] || { [ -f "$manifest" ] && [ ! -L "$manifest" ]; }; command -v mktemp >/dev/null 2>&1 || { printf "Remote command is unavailable: mktemp\n" >&2; exit 69; }; command -v head >/dev/null 2>&1 || { printf "Remote command is unavailable: head\n" >&2; exit 69; }; command -v wc >/dev/null 2>&1 || { printf "Remote command is unavailable: wc\n" >&2; exit 69; }; temporary=$(mktemp "${manifest}.tmp.XXXXXX"); cleanup() { rm -f -- "$temporary"; }; trap cleanup EXIT HUP INT TERM; head -c "$max_plus_one" > "$temporary"; size=$(wc -c < "$temporary"); [ "$size" -le "$max_bytes" ] || { printf "Manifest exceeds %s bytes\n" "$max_bytes" >&2; exit 65; }; [ "$size" -eq "$expected_bytes" ] || { printf "Manifest transfer was truncated or changed size\n" >&2; exit 74; }; chmod 600 -- "$temporary"; mv -f -- "$temporary" "$manifest"; chmod 600 -- "$manifest"; trap - EXIT HUP INT TERM'
    command="$(_remote_build_shell_command \
      "$script" "$metadata_directory" "$manifest" "$max_bytes" "$max_plus_one" "$byte_count")"
    ssh "${SSH_OPTIONS[@]}" "$SSH_TARGET" "$command" < "$local_manifest" \
      || return 1
    remote_lock_verify
    return
  fi

  [[ ! -e "$metadata_directory" \
    || ( -d "$metadata_directory" && ! -L "$metadata_directory" ) ]] \
    || die "Refusing unsafe recovery metadata directory: $metadata_directory"
  mkdir -p -- "$metadata_directory" || return 1
  chmod 0700 -- "$metadata_directory" || return 1
  [[ ! -e "$manifest" || ( -f "$manifest" && ! -L "$manifest" ) ]] \
    || die "Refusing unsafe recovery manifest path: $manifest"
  temporary="$(mktemp "${manifest}.tmp.XXXXXX")"
  chmod 0600 -- "$temporary" || {
    rm -f -- "$temporary"
    return 1
  }
  if ! cp -- "$local_manifest" "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  staged_count="$(wc -c < "$temporary")" || staged_count=''
  staged_count="$(trim "$staged_count")"
  if [[ "$staged_count" != "$byte_count" ]]; then
    rm -f -- "$temporary"
    warn 'Recovery manifest changed size while it was being staged.'
    return 1
  fi
  if ! mv -f -- "$temporary" "$manifest"; then
    rm -f -- "$temporary"
    return 1
  fi
  chmod 0600 -- "$manifest" || return 1
  remote_lock_verify
}

remote_remove_manifest() {
  local kind="$1"
  local metadata_directory="${ACTIVE_HOST_BASE}/.mint-jelly"
  local manifest="${metadata_directory}/$(remote_manifest_filename "$kind")"

  remote_require_lock exclusive
  remote_assert_mirror_path "$metadata_directory" directory

  if [[ "$ACTIVE_REMOTE_TYPE" == 'ssh' ]]; then
    remote_exec_script '
set -eu
metadata_directory=$1
manifest=$2
[ ! -e "$metadata_directory" ] || {
  [ -d "$metadata_directory" ] && [ ! -L "$metadata_directory" ]
}
rm -f -- "$manifest"
' "$metadata_directory" "$manifest" || return 1
    remote_lock_verify
    return
  fi

  [[ ! -e "$metadata_directory" \
    || ( -d "$metadata_directory" && ! -L "$metadata_directory" ) ]] \
    || die "Refusing unsafe recovery metadata directory: $metadata_directory"
  rm -f -- "$manifest" || return 1
  remote_lock_verify
}

remote_read_manifest() {
  local kind="$1"
  local metadata_directory="${ACTIVE_HOST_BASE}/.mint-jelly"
  local manifest="${metadata_directory}/$(remote_manifest_filename "$kind")"
  local max_bytes="${2:-1048576}"
  local max_plus_one=$((max_bytes + 1))

  remote_require_lock shared
  remote_assert_mirror_path "$metadata_directory" directory
  if [[ "$ACTIVE_REMOTE_TYPE" == 'ssh' ]]; then
    remote_exec_script '
set -eu
metadata_directory=$1
manifest=$2
max_plus_one=$3
[ -d "$metadata_directory" ] && [ ! -L "$metadata_directory" ] \
  && [ -f "$manifest" ] && [ ! -L "$manifest" ]
command -v head >/dev/null 2>&1 || {
  printf "Remote command is unavailable: head\n" >&2
  exit 69
}
head -c "$max_plus_one" -- "$manifest"
' "$metadata_directory" "$manifest" "$max_plus_one" || return 1
    remote_lock_verify
    return
  fi

  [[ -d "$metadata_directory" && ! -L "$metadata_directory" \
    && -f "$manifest" && ! -L "$manifest" ]] || return 1
  require_cmd head
  head -c "$max_plus_one" -- "$manifest" || return 1
  remote_lock_verify
}

remote_write_recovery_manifest() {
  remote_write_manifest files "$1" "${RECOVERY_MANIFEST_MAX_BYTES:-1048576}"
}

remote_invalidate_recovery_manifest() {
  remote_remove_manifest files
}

remote_read_recovery_manifest() {
  remote_read_manifest files "${RECOVERY_MANIFEST_MAX_BYTES:-1048576}"
}

remote_backup_source_exists() {
  local source="$1"
  local backup_path="${ACTIVE_HOST_BASE}/${source#/}"
  local status=0

  remote_require_lock shared
  validate_absolute_path "$source" \
    || die "Refusing to inspect an unsafe backup source: $source"
  remote_assert_mirror_path "$backup_path" leaf

  if [[ "$ACTIVE_REMOTE_TYPE" == 'ssh' ]]; then
    remote_exec_script '
set -eu
path=$1
[ -e "$path" ] || [ -L "$path" ]
' "$backup_path" || status=$?
    remote_lock_verify
    return "$status"
  fi

  [[ -e "$backup_path" || -L "$backup_path" ]] || status=$?
  remote_lock_verify
  return "$status"
}

remote_regular_file_exists() {
  local path="$1"
  local status=0

  remote_require_lock shared
  [[ "$path" == "$ACTIVE_HOST_BASE/"* ]] \
    || die "Refusing to inspect a path outside the active backup: $path"
  remote_assert_mirror_path "$path" leaf

  if [[ "$ACTIVE_REMOTE_TYPE" == 'ssh' ]]; then
    remote_exec_script '
set -eu
path=$1
[ -f "$path" ] && [ ! -L "$path" ]
' "$path" || status=$?
    remote_lock_verify
    return "$status"
  fi

  [[ -f "$path" && ! -L "$path" ]] || status=$?
  remote_lock_verify
  return "$status"
}

remote_restore_source() {
  local source="$1"
  local dry_run="$2"
  local relative_path
  local source_argument
  local -a options=(
    --archive
    --human-readable
    --itemize-changes
    --relative
    --no-implied-dirs
  )

  remote_require_lock shared
  validate_absolute_path "$source" \
    || die "Refusing to restore an unsafe source path: $source"
  require_cmd rsync
  [[ "$dry_run" == 'true' ]] && options+=(--dry-run)
  relative_path="${source#/}"
  remote_assert_mirror_path "${ACTIVE_HOST_BASE}/${relative_path}" leaf

  if [[ "$ACTIVE_REMOTE_TYPE" == 'ssh' ]]; then
    options+=(--protect-args -e "ssh -p $SSH_PORT -o ControlPath=$SSH_CONTROL_PATH")
    source_argument="${SSH_TARGET}:${ACTIVE_HOST_BASE}/./${relative_path}"
  else
    source_argument="${ACTIVE_HOST_BASE}/./${relative_path}"
  fi

  rsync "${options[@]}" -- "$source_argument" / || return 1
  remote_lock_verify
}

remote_cleanup_history() {
  local keep="$1"
  local history_root="${ACTIVE_HOST_BASE}/.history"
  local candidate generation
  local remove_count index status=0
  local -a candidates=() generations=()

  remote_require_lock exclusive
  [[ "$keep" =~ ^(0|[1-9][0-9]*)$ ]] \
    || die "Invalid history retention count: $keep"
  remote_assert_mirror_path "$history_root" directory

  if [[ "$ACTIVE_REMOTE_TYPE" == 'ssh' ]]; then
    remote_exec_script '
set -eu
history_root=$1
keep=$2

[ -e "$history_root" ] || exit 0
[ ! -L "$history_root" ] || {
  printf "Refusing to clean a symbolic-link history root: %s\n" "$history_root" >&2
  exit 1
}

# Remove leaf directories first so generations that contain no saved files
# disappear before they are counted toward retention.
find "$history_root" -depth -mindepth 1 -type d -empty -delete
[ -d "$history_root" ] || exit 0

LC_ALL=C
export LC_ALL
set --
for path in "$history_root"/*; do
  [ -d "$path" ] && [ ! -L "$path" ] || continue
  name=${path##*/}
  case "$name" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z)
      set -- "$@" "$name"
      ;;
  esac
done

remove_count=$(($# - keep))
while [ "$remove_count" -gt 0 ]; do
  printf "Removing expired history generation: %s\n" "$1"
  rm -rf -- "$history_root/$1"
  shift
  remove_count=$((remove_count - 1))
done

find "$history_root" -depth -mindepth 1 -type d -empty -delete
rmdir -- "$history_root" 2>/dev/null || true
' "$history_root" "$keep" || status=$?
    remote_lock_verify
    return "$status"
  fi

  [[ -e "$history_root" ]] || return 0
  if [[ -L "$history_root" ]]; then
    printf 'Refusing to clean a symbolic-link history root: %s\n' \
      "$history_root" >&2
    return 1
  fi

  find "$history_root" -depth -mindepth 1 -type d -empty -delete || return 1
  [[ -d "$history_root" ]] || return 0

  mapfile -t candidates < <(
    find "$history_root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
      | LC_ALL=C sort
  )
  for candidate in "${candidates[@]}"; do
    if [[ "$candidate" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
      generations+=("$candidate")
    fi
  done

  remove_count=$((${#generations[@]} - 10#$keep))
  for ((index = 0; index < remove_count; index += 1)); do
    generation="${generations[$index]}"
    log "Removing expired history generation: $generation"
    rm -rf -- "$history_root/$generation" || return 1
  done

  find "$history_root" -depth -mindepth 1 -type d -empty -delete || return 1
  rmdir -- "$history_root" 2>/dev/null || true
  remote_lock_verify
}

remote_validate_candidate() {
  local name="$1"
  local machine_name

  machine_name="$(hostname)"
  remote_open "$name" "$machine_name"
  remote_lock_acquire exclusive
  remote_lock_verify
  remote_lock_release \
    || die "Could not release the remote operation lock for '$name'."
  remote_close
}
