#!/usr/bin/env bash

# Atomic generation storage shared by files, software, and system settings.

SNAPSHOT_FORMAT='2'
SNAPSHOT_ID=''
SNAPSHOT_STAGE=''
SNAPSHOT_BASE=''
SNAPSHOT_MAX_MANIFEST_BYTES=4194304

snapshot_begin() {
  local copy_current="${1:-true}" metadata snapshots current old_id
  metadata="${ACTIVE_HOST_BASE}/.mint-jelly"
  snapshots="$metadata/snapshots"
  current="$metadata/current"
  remote_require_lock exclusive
  SNAPSHOT_ID="$(date -u '+%Y%m%dT%H%M%S')-$$-$RANDOM"
  SNAPSHOT_STAGE="$snapshots/.staging-$SNAPSHOT_ID"
  SNAPSHOT_BASE="$snapshots/$SNAPSHOT_ID"
  validate_safe_name "$SNAPSHOT_ID" || die 'Could not create a safe snapshot ID.'
  if [[ "$ACTIVE_REMOTE_TYPE" == 'ssh' ]]; then
    remote_exec_script '
set -eu
metadata=$1; snapshots=$2; current=$3; stage=$4; copy_current=$5
umask 077
[ ! -L "$metadata" ] && { [ ! -e "$metadata" ] || [ -d "$metadata" ]; }
mkdir -p -- "$snapshots"
[ -d "$snapshots" ] && [ ! -L "$snapshots" ]
[ ! -e "$stage" ] && [ ! -L "$stage" ]
if [ "$copy_current" = true ] && [ -f "$current" ] && [ ! -L "$current" ]; then
  old_id=$(sed -n "1p" "$current")
  case "$old_id" in *[!A-Za-z0-9._-]*|""|.|..) exit 65 ;; esac
  old="$snapshots/$old_id"
  [ -d "$old" ] && [ ! -L "$old"
  ]
  if ! cp -al -- "$old" "$stage"; then
    rm -rf -- "$stage"
    cp -a -- "$old" "$stage"
  fi
else
  mkdir -- "$stage"
fi
chmod 700 -- "$metadata" "$snapshots" "$stage"
' "$metadata" "$snapshots" "$current" "$SNAPSHOT_STAGE" "$copy_current" \
      || die 'Could not create the remote snapshot staging area.'
  else
    [[ ! -L "$metadata" && ( ! -e "$metadata" || -d "$metadata" ) ]] \
      || die "Unsafe snapshot metadata directory: $metadata"
    mkdir -p -- "$snapshots"
    [[ -d "$snapshots" && ! -L "$snapshots" ]] || die "Unsafe snapshots directory: $snapshots"
    if [[ "$copy_current" == 'true' && -f "$current" && ! -L "$current" ]]; then
      old_id="$(sed -n '1p' "$current")"
      validate_safe_name "$old_id" || die 'Current snapshot pointer is invalid.'
      [[ -d "$snapshots/$old_id" && ! -L "$snapshots/$old_id" ]] \
        || die 'Current snapshot generation is missing or unsafe.'
      if ! cp -al -- "$snapshots/$old_id" "$SNAPSHOT_STAGE"; then
        rm -rf -- "$SNAPSHOT_STAGE"
        cp -a -- "$snapshots/$old_id" "$SNAPSHOT_STAGE"
      fi
    else
      mkdir -- "$SNAPSHOT_STAGE"
    fi
    chmod 0700 -- "$metadata" "$snapshots" "$SNAPSHOT_STAGE"
  fi
  remote_lock_verify
}

snapshot_abort() {
  [[ -n "$SNAPSHOT_STAGE" ]] || return 0
  if [[ "$ACTIVE_REMOTE_TYPE" == 'ssh' ]]; then
    remote_exec_script 'set -eu; stage=$1; case "$stage" in */snapshots/.staging-*) rm -rf -- "$stage" ;; *) exit 65 ;; esac' \
      "$SNAPSHOT_STAGE" || true
  elif [[ "$SNAPSHOT_STAGE" == "$ACTIVE_HOST_BASE/.mint-jelly/snapshots/.staging-"* ]]; then
    rm -rf -- "$SNAPSHOT_STAGE"
  fi
  SNAPSHOT_STAGE=''
}

snapshot_reset_domain() {
  local domain="$1"
  validate_safe_name "$domain" || die "Invalid snapshot domain: $domain"
  [[ -n "$SNAPSHOT_STAGE" ]] || die 'No snapshot is being staged.'
  if [[ "$ACTIVE_REMOTE_TYPE" == 'ssh' ]]; then
    remote_exec_script '
set -eu
stage=$1; domain=$2
case "$stage" in */snapshots/.staging-*) ;; *) exit 65 ;; esac
rm -rf -- "$stage/data/$domain"
rm -f -- "$stage/$domain.manifest"
mkdir -p -- "$stage/data/$domain/root"
' "$SNAPSHOT_STAGE" "$domain" || die "Could not reset snapshot domain '$domain'."
  else
    rm -rf -- "$SNAPSHOT_STAGE/data/$domain"
    rm -f -- "$SNAPSHOT_STAGE/$domain.manifest"
    mkdir -p -- "$SNAPSHOT_STAGE/data/$domain/root"
  fi
}

snapshot_upload_manifest() {
  local domain="$1" source="$2" destination size temporary command
  destination="$SNAPSHOT_STAGE/$domain.manifest"
  validate_safe_name "$domain" || die "Invalid snapshot domain: $domain"
  [[ -f "$source" && ! -L "$source" ]] || die "Unsafe manifest source: $source"
  size="$(wc -c < "$source")"
  (( size > 0 && size <= SNAPSHOT_MAX_MANIFEST_BYTES )) \
    || die "Snapshot manifest must contain 1-$SNAPSHOT_MAX_MANIFEST_BYTES bytes."
  if [[ "$ACTIVE_REMOTE_TYPE" == 'ssh' ]]; then
    command="$(_remote_build_shell_command 'set -eu; destination=$1; size=$2; temporary="${destination}.tmp.$$"; umask 077; trap '\''rm -f -- "$temporary"'\'' EXIT; head -c "$size" > "$temporary"; [ "$(wc -c < "$temporary")" -eq "$size" ]; chmod 600 -- "$temporary"; mv -f -- "$temporary" "$destination"; trap - EXIT' "$destination" "$size")"
    ssh "${SSH_OPTIONS[@]}" "$SSH_TARGET" "$command" < "$source" \
      || die "Could not upload $domain manifest."
  else
    temporary="$(mktemp "${destination}.tmp.XXXXXX")"
    chmod 0600 -- "$temporary"
    cp -- "$source" "$temporary"
    mv -f -- "$temporary" "$destination"
  fi
  remote_lock_verify
}

snapshot_sync_absolute() {
  local source="$1" domain="$2" destination source_argument destination_argument normalized_source normalized_destination
  local -a options=(--archive --relative --no-implied-dirs --human-readable --itemize-changes)
  destination="$SNAPSHOT_STAGE/data/$domain/root/"
  source_argument="/./${source#/}"
  validate_absolute_path "$source" || die "Unsafe snapshot source: $source"
  validate_safe_name "$domain" || die "Invalid snapshot domain: $domain"
  [[ -e "$source" || -L "$source" ]] || return 2
  require_cmd rsync
  if [[ "$ACTIVE_REMOTE_TYPE" == 'local' && -d "$source" && ! -L "$source" ]]; then
    normalized_source="$(realpath -m -- "$source")"
    normalized_destination="$(realpath -m -- "$ACTIVE_HOST_BASE")"
    [[ "$normalized_destination" != "$normalized_source" \
      && "$normalized_destination" != "$normalized_source/"* ]] \
      || die "Backup destination is inside configured source: $source"
  fi
  if [[ "$ACTIVE_REMOTE_TYPE" == 'ssh' ]]; then
    options+=(--protect-args -e "ssh -p $SSH_PORT -o ControlPath=$SSH_CONTROL_PATH")
    destination_argument="${SSH_TARGET}:${destination}"
  else
    destination_argument="$destination"
  fi
  rsync "${options[@]}" -- "$source_argument" "$destination_argument" \
    || die "Could not snapshot $source"
  remote_lock_verify
}

snapshot_commit() {
  local metadata snapshots current keep temporary remove_count index
  local -a generations=()
  metadata="${ACTIVE_HOST_BASE}/.mint-jelly"
  snapshots="$metadata/snapshots"
  current="$metadata/current"
  keep="${1:-5}"
  [[ -n "$SNAPSHOT_STAGE" && -n "$SNAPSHOT_BASE" ]] || die 'No snapshot is being staged.'
  [[ "$keep" =~ ^(0|[1-9][0-9]*)$ ]] || die 'Invalid snapshot retention count.'
  if [[ "$ACTIVE_REMOTE_TYPE" == 'ssh' ]]; then
    remote_exec_script '
set -eu
stage=$1; final=$2; current=$3; id=$4; snapshots=$5; keep=$6
[ -d "$stage" ] && [ ! -L "$stage" ]; [ ! -e "$final" ] && [ ! -L "$final" ]
mv -- "$stage" "$final"
temporary="${current}.tmp.$$"; trap '\''rm -f -- "$temporary"'\'' EXIT
printf "%s\n" "$id" > "$temporary"; chmod 600 -- "$temporary"; mv -f -- "$temporary" "$current"
trap - EXIT
set -- "$snapshots"/[0-9]*; [ -e "$1" ] || exit 0
count=$#; remove=$((count - keep)); [ "$remove" -gt 0 ] || exit 0
printf "%s\n" "$@" | sort | head -n "$remove" | while IFS= read -r old; do
  [ "$old" = "$final" ] || rm -rf -- "$old"
done
' "$SNAPSHOT_STAGE" "$SNAPSHOT_BASE" "$current" "$SNAPSHOT_ID" "$snapshots" "$keep" \
      || die 'Could not atomically commit the remote snapshot.'
  else
    mv -- "$SNAPSHOT_STAGE" "$SNAPSHOT_BASE"
    temporary="$(mktemp "${current}.tmp.XXXXXX")"
    printf '%s\n' "$SNAPSHOT_ID" > "$temporary"
    chmod 0600 -- "$temporary"
    mv -f -- "$temporary" "$current"
    mapfile -t generations < <(find "$snapshots" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' -printf '%p\n' | sort)
    if (( ${#generations[@]} > keep )); then
      remove_count=$((${#generations[@]} - keep))
      for (( index=0; index<remove_count; index++ )); do
        [[ "${generations[$index]}" == "$SNAPSHOT_BASE" ]] || rm -rf -- "${generations[$index]}"
      done
    fi
  fi
  SNAPSHOT_STAGE=''
  remote_lock_verify
}

snapshot_select_current() {
  local metadata current id
  metadata="${ACTIVE_HOST_BASE}/.mint-jelly"
  current="$metadata/current"
  remote_require_lock shared
  if [[ "$ACTIVE_REMOTE_TYPE" == 'ssh' ]]; then
    id="$(remote_exec_script 'set -eu; current=$1; [ -f "$current" ] && [ ! -L "$current" ]; sed -n "1p" "$current"' "$current")" \
      || die 'No current snapshot exists for this source host.'
  else
    [[ -f "$current" && ! -L "$current" ]] || die 'No current snapshot exists for this source host.'
    id="$(sed -n '1p' "$current")"
  fi
  validate_safe_name "$id" || die 'Current snapshot pointer is invalid.'
  SNAPSHOT_ID="$id"
  SNAPSHOT_BASE="$metadata/snapshots/$id"
  if [[ "$ACTIVE_REMOTE_TYPE" == 'ssh' ]]; then
    remote_exec_script 'set -eu; path=$1; [ -d "$path" ] && [ ! -L "$path" ]' "$SNAPSHOT_BASE" \
      || die 'Current snapshot generation is missing or unsafe.'
  else
    [[ -d "$SNAPSHOT_BASE" && ! -L "$SNAPSHOT_BASE" ]] \
      || die 'Current snapshot generation is missing or unsafe.'
  fi
  remote_lock_verify
}

snapshot_read_manifest() {
  local domain="$1" path size
  path="$SNAPSHOT_BASE/$domain.manifest"
  validate_safe_name "$domain" || die "Invalid snapshot domain: $domain"
  if [[ "$ACTIVE_REMOTE_TYPE" == 'ssh' ]]; then
    remote_exec_script 'set -eu; path=$1; maximum=$2; [ -f "$path" ] && [ ! -L "$path" ]; size=$(wc -c < "$path"); [ "$size" -gt 0 ] && [ "$size" -le "$maximum" ]; cat -- "$path"' \
      "$path" "$SNAPSHOT_MAX_MANIFEST_BYTES"
  else
    [[ -f "$path" && ! -L "$path" ]] || return 1
    size="$(wc -c < "$path")"
    (( size > 0 && size <= SNAPSHOT_MAX_MANIFEST_BYTES )) || return 1
    cat -- "$path"
  fi
}

snapshot_restore_absolute() {
  local path="$1" dry_run="$2" relative source source_argument
  local -a options=(--archive --relative --no-implied-dirs --human-readable --itemize-changes)
  relative="${path#/}"
  source="$SNAPSHOT_BASE/data/$SNAPSHOT_RESTORE_DOMAIN/root/./$relative"
  validate_absolute_path "$path" || die "Unsafe restore path: $path"
  validate_safe_name "$SNAPSHOT_RESTORE_DOMAIN" || die 'Invalid restore domain.'
  require_cmd rsync
  [[ "$dry_run" == 'true' ]] && options+=(--dry-run)
  if [[ "$ACTIVE_REMOTE_TYPE" == 'ssh' ]]; then
    options+=(--protect-args -e "ssh -p $SSH_PORT -o ControlPath=$SSH_CONTROL_PATH")
    source_argument="${SSH_TARGET}:${source}"
  else
    source_argument="$source"
  fi
  rsync "${options[@]}" -- "$source_argument" / || die "Could not restore $path"
  remote_lock_verify
}
