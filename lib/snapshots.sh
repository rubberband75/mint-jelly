#!/usr/bin/env bash

# Atomic generation storage shared by every recovery domain.

SNAPSHOT_FORMAT='3'
SNAPSHOT_ID=''
SNAPSHOT_STAGE=''
SNAPSHOT_BASE=''
SNAPSHOT_PREVIOUS_BASE=''
SNAPSHOT_MAX_MANIFEST_BYTES=4194304

snapshot_current_format() {
  local metadata current id manifest format

  metadata="${ACTIVE_HOST_BASE}/.mint-jelly"
  current="$metadata/current"
  remote_require_lock shared
  if [[ "$ACTIVE_REMOTE_TYPE" == 'ssh' ]]; then
    format="$(remote_exec_script '
set -eu
current=$1; snapshots=$2
[ -f "$current" ] && [ ! -L "$current" ] || exit 3
id=$(sed -n "1p" "$current")
case "$id" in *[!A-Za-z0-9._-]*|""|.|..) exit 65 ;; esac
manifest="$snapshots/$id/snapshot.manifest"
[ -f "$manifest" ] && [ ! -L "$manifest" ] || exit 3
sed -n "s/^version=//p" "$manifest" | sed -n "1p"
' "$current" "$metadata/snapshots")" || return $?
  else
    [[ -f "$current" && ! -L "$current" ]] || return 3
    id="$(sed -n '1p' "$current")"
    validate_safe_name "$id" || die 'Current snapshot pointer is invalid.'
    manifest="$metadata/snapshots/$id/snapshot.manifest"
    [[ -f "$manifest" && ! -L "$manifest" ]] || return 3
    format="$(sed -n 's/^version=//p' "$manifest" | sed -n '1p')"
  fi
  [[ -n "$format" ]] || return 3
  printf '%s' "$format"
  remote_lock_verify
}

snapshot_assert_format() {
  local manifest format domain

  manifest="$(snapshot_read_manifest snapshot)" \
    || die "Snapshot $SNAPSHOT_ID is missing its root manifest."
  format="$(sed -n 's/^version=//p' <<< "$manifest" | sed -n '1p')"
  domain="$(sed -n 's/^domain=//p' <<< "$manifest" | sed -n '1p')"
  [[ "$format" == "$SNAPSHOT_FORMAT" && "$domain" == 'snapshot' ]] \
    || die "Snapshot $SNAPSHOT_ID uses unsupported format '${format:-unknown}'; expected $SNAPSHOT_FORMAT."
}

snapshot_begin() {
  local copy_current="${1:-true}" metadata snapshots current old_id
  metadata="${ACTIVE_HOST_BASE}/.mint-jelly"
  snapshots="$metadata/snapshots"
  current="$metadata/current"
  remote_require_lock exclusive
  SNAPSHOT_ID="$(date -u '+%Y%m%dT%H%M%S')-$$-$RANDOM"
  SNAPSHOT_STAGE="$snapshots/.staging-$SNAPSHOT_ID"
  SNAPSHOT_BASE="$snapshots/$SNAPSHOT_ID"
  SNAPSHOT_PREVIOUS_BASE=''
  validate_safe_name "$SNAPSHOT_ID" || die 'Could not create a safe snapshot ID.'
  if [[ "$ACTIVE_REMOTE_TYPE" == 'ssh' ]]; then
    if [[ "$copy_current" == 'true' ]]; then
      old_id="$(remote_exec_script '
set -eu
current=$1
if [ -e "$current" ] || [ -L "$current" ]; then
  [ -f "$current" ] && [ ! -L "$current" ]
  sed -n "1p" "$current"
fi
' "$current")" || die 'Could not inspect the current remote snapshot pointer.'
      if [[ -n "$old_id" ]]; then
        validate_safe_name "$old_id" || die 'Current snapshot pointer is invalid.'
        SNAPSHOT_PREVIOUS_BASE="$snapshots/$old_id"
      fi
    fi
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
[ ! -e "$stage/data" ] && [ ! -L "$stage/data" ] || { [ -d "$stage/data" ] && [ ! -L "$stage/data" ]; }
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
      SNAPSHOT_PREVIOUS_BASE="$snapshots/$old_id"
      [[ -d "$snapshots/$old_id" && ! -L "$snapshots/$old_id" ]] \
        || die 'Current snapshot generation is missing or unsafe.'
      if ! cp -al -- "$snapshots/$old_id" "$SNAPSHOT_STAGE"; then
        rm -rf -- "$SNAPSHOT_STAGE"
        cp -a -- "$snapshots/$old_id" "$SNAPSHOT_STAGE"
      fi
    else
      mkdir -- "$SNAPSHOT_STAGE"
    fi
    [[ ! -e "$SNAPSHOT_STAGE/data" && ! -L "$SNAPSHOT_STAGE/data" \
      || ( -d "$SNAPSHOT_STAGE/data" && ! -L "$SNAPSHOT_STAGE/data" ) ]] \
      || die 'Current snapshot contains an unsafe data directory.'
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
  local domain="$1" layout="${2:-root}"
  validate_safe_name "$domain" || die "Invalid snapshot domain: $domain"
  [[ "$layout" == 'root' || "$layout" == 'structured' ]] \
    || die "Invalid snapshot domain layout: $layout"
  [[ -n "$SNAPSHOT_STAGE" ]] || die 'No snapshot is being staged.'
  if [[ "$ACTIVE_REMOTE_TYPE" == 'ssh' ]]; then
    remote_exec_script '
set -eu
stage=$1; domain=$2; layout=$3
case "$stage" in */snapshots/.staging-*) ;; *) exit 65 ;; esac
[ -d "$stage" ] && [ ! -L "$stage" ]
data="$stage/data"
[ ! -e "$data" ] && [ ! -L "$data" ] || { [ -d "$data" ] && [ ! -L "$data" ]; }
mkdir -p -- "$data"
rm -rf -- "$stage/data/$domain"
rm -f -- "$stage/$domain.manifest"
mkdir -p -- "$stage/data/$domain"
[ "$layout" != root ] || mkdir -p -- "$stage/data/$domain/root"
' "$SNAPSHOT_STAGE" "$domain" "$layout" || die "Could not reset snapshot domain '$domain'."
  else
    [[ -d "$SNAPSHOT_STAGE" && ! -L "$SNAPSHOT_STAGE" ]] || die 'Unsafe snapshot staging directory.'
    [[ ! -e "$SNAPSHOT_STAGE/data" && ! -L "$SNAPSHOT_STAGE/data" \
      || ( -d "$SNAPSHOT_STAGE/data" && ! -L "$SNAPSHOT_STAGE/data" ) ]] \
      || die 'Unsafe snapshot staging data directory.'
    mkdir -p -- "$SNAPSHOT_STAGE/data"
    rm -rf -- "$SNAPSHOT_STAGE/data/$domain"
    rm -f -- "$SNAPSHOT_STAGE/$domain.manifest"
    mkdir -p -- "$SNAPSHOT_STAGE/data/$domain"
    [[ "$layout" != 'root' ]] || mkdir -p -- "$SNAPSHOT_STAGE/data/$domain/root"
  fi
}

snapshot_prepare_structured_domain() {
  local domain="$1" preserve_all='false' entry path name keep allowed
  shift
  if [[ "${1-}" == '--preserve-all' ]]; then
    preserve_all='true'
    shift
  fi
  validate_safe_name "$domain" || die "Invalid snapshot domain: $domain"
  for entry in "$@"; do validate_safe_name "$entry" || die "Invalid snapshot entry: $entry"; done
  [[ -n "$SNAPSHOT_STAGE" ]] || die 'No snapshot is being staged.'

  if [[ "$ACTIVE_REMOTE_TYPE" == 'ssh' ]]; then
    remote_exec_script '
set -eu
stage=$1; domain=$2; preserve_all=$3; shift 3
case "$stage" in */snapshots/.staging-*) ;; *) exit 65 ;; esac
[ -d "$stage" ] && [ ! -L "$stage" ]
data="$stage/data"
[ ! -e "$data" ] && [ ! -L "$data" ] || { [ -d "$data" ] && [ ! -L "$data" ]; }
mkdir -p -- "$data"
root="$stage/data/$domain"
rm -f -- "$stage/$domain.manifest"
[ ! -e "$root" ] && [ ! -L "$root" ] || { [ -d "$root" ] && [ ! -L "$root" ]; }
mkdir -- "$root" 2>/dev/null || [ -d "$root" ]
for path in "$root"/* "$root"/.[!.]* "$root"/..?*; do
  [ -e "$path" ] || [ -L "$path" ] || continue
  [ -d "$path" ] && [ ! -L "$path" ] || exit 66
  name=${path##*/}
  case "$name" in [A-Za-z0-9]*) ;; *) exit 65 ;; esac
  case "$name" in *[!A-Za-z0-9._-]*|.|..) exit 65 ;; esac
  keep=$preserve_all
  for allowed in "$@"; do [ "$name" != "$allowed" ] || keep=true; done
  [ "$keep" = true ] || rm -rf -- "$path"
done
' "$SNAPSHOT_STAGE" "$domain" "$preserve_all" "$@" \
      || die "Could not prepare structured snapshot domain '$domain'."
  else
    [[ -d "$SNAPSHOT_STAGE" && ! -L "$SNAPSHOT_STAGE" ]] || die 'Unsafe snapshot staging directory.'
    [[ ! -e "$SNAPSHOT_STAGE/data" && ! -L "$SNAPSHOT_STAGE/data" \
      || ( -d "$SNAPSHOT_STAGE/data" && ! -L "$SNAPSHOT_STAGE/data" ) ]] \
      || die 'Unsafe snapshot staging data directory.'
    mkdir -p -- "$SNAPSHOT_STAGE/data"
    rm -f -- "$SNAPSHOT_STAGE/$domain.manifest"
    [[ ! -e "$SNAPSHOT_STAGE/data/$domain" && ! -L "$SNAPSHOT_STAGE/data/$domain" \
      || ( -d "$SNAPSHOT_STAGE/data/$domain" && ! -L "$SNAPSHOT_STAGE/data/$domain" ) ]] \
      || die "Unsafe structured snapshot domain: $domain"
    mkdir -p -- "$SNAPSHOT_STAGE/data/$domain"
    [[ -d "$SNAPSHOT_STAGE/data/$domain" && ! -L "$SNAPSHOT_STAGE/data/$domain" ]] \
      || die "Unsafe structured snapshot domain: $domain"
    shopt -s nullglob dotglob
    for path in "$SNAPSHOT_STAGE/data/$domain"/*; do
      [[ -d "$path" && ! -L "$path" ]] || die "Unsafe structured snapshot entry: $path"
      name="${path##*/}"
      validate_safe_name "$name" || die "Unsafe structured snapshot entry: $name"
      keep="$preserve_all"
      for allowed in "$@"; do [[ "$name" != "$allowed" ]] || keep='true'; done
      [[ "$keep" == 'true' ]] || rm -rf -- "$path"
    done
    shopt -u nullglob dotglob
  fi
  remote_lock_verify
}

snapshot_staged_domain_entry_exists() {
  local domain="$1" entry="$2" path status=0
  validate_safe_name "$domain" || die "Invalid snapshot domain: $domain"
  validate_safe_name "$entry" || die "Invalid snapshot entry: $entry"
  path="$SNAPSHOT_STAGE/data/$domain/$entry"
  if [[ "$ACTIVE_REMOTE_TYPE" == 'ssh' ]]; then
    remote_exec_script 'set -eu; path=$1; [ -d "$path" ] && [ ! -L "$path" ]' "$path" || status=$?
  else
    [[ -d "$path" && ! -L "$path" ]] || status=$?
  fi
  remote_lock_verify
  return "$status"
}

snapshot_list_staged_domain_entries() {
  local domain="$1" root path name

  validate_safe_name "$domain" || die "Invalid snapshot domain: $domain"
  root="$SNAPSHOT_STAGE/data/$domain"
  remote_assert_mirror_path "$root" directory
  if [[ "$ACTIVE_REMOTE_TYPE" == ssh ]]; then
    remote_exec_script '
set -eu
root=$1
[ -d "$root" ] && [ ! -L "$root" ]
for path in "$root"/* "$root"/.[!.]* "$root"/..?*; do
  [ -e "$path" ] || [ -L "$path" ] || continue
  [ -d "$path" ] && [ ! -L "$path" ] || exit 66
  name=${path##*/}
  case "$name" in [A-Za-z0-9]*) ;; *) exit 65 ;; esac
  case "$name" in *[!A-Za-z0-9._-]*|.|..) exit 65 ;; esac
  printf "%s\n" "$name"
done
' "$root" | LC_ALL=C sort
  else
    [[ -d "$root" && ! -L "$root" ]] || die "Unsafe structured snapshot domain: $domain"
    shopt -s nullglob dotglob
    for path in "$root"/*; do
      [[ -d "$path" && ! -L "$path" ]] || die "Unsafe structured snapshot entry: $path"
      name="${path##*/}"
      validate_safe_name "$name" || die "Unsafe structured snapshot entry: $name"
      printf '%s\n' "$name"
    done | LC_ALL=C sort
    shopt -u nullglob dotglob
  fi
  remote_lock_verify
}

snapshot_download_staged_domain_file() {
  local domain="$1" entry="$2" filename="$3" destination="$4" maximum="${5:-16777216}"
  local source size

  validate_safe_name "$domain" || die "Invalid snapshot domain: $domain"
  validate_safe_name "$entry" || die "Invalid snapshot entry: $entry"
  validate_safe_name "$filename" || die "Invalid snapshot entry filename: $filename"
  [[ "$maximum" =~ ^[1-9][0-9]*$ ]] || die 'Invalid staged-file size limit.'
  [[ ! -e "$destination" && ! -L "$destination" ]] \
    || die "Staged-file download destination already exists: $destination"
  source="$SNAPSHOT_STAGE/data/$domain/$entry/$filename"
  remote_assert_mirror_path "$source" leaf
  if [[ "$ACTIVE_REMOTE_TYPE" == ssh ]]; then
    if ! remote_exec_script '
set -eu
path=$1; maximum=$2
[ -f "$path" ] && [ ! -L "$path" ]
size=$(wc -c < "$path")
[ "$size" -gt 0 ] && [ "$size" -le "$maximum" ]
cat -- "$path"
' "$source" "$maximum" > "$destination"; then
      rm -f -- "$destination"
      die "Could not download staged snapshot metadata: $domain/$entry/$filename"
    fi
  else
    [[ -f "$source" && ! -L "$source" ]] \
      || die "Staged snapshot metadata is missing or unsafe: $domain/$entry/$filename"
    size="$(wc -c < "$source")"
    (( size > 0 && size <= maximum )) \
      || die "Staged snapshot metadata has an unsafe size: $domain/$entry/$filename"
    cp -- "$source" "$destination"
  fi
  chmod 0600 -- "$destination"
  remote_lock_verify
}

snapshot_sync_domain_entry() {
  local source="$1" domain="$2" entry="$3" destination destination_argument previous
  local has_previous='false'
  local -a options=(--archive --checksum --delete --human-readable --itemize-changes)

  [[ -d "$source" && ! -L "$source" ]] || die "Unsafe structured snapshot source: $source"
  validate_safe_name "$domain" || die "Invalid snapshot domain: $domain"
  validate_safe_name "$entry" || die "Invalid snapshot entry: $entry"
  destination="$SNAPSHOT_STAGE/data/$domain/$entry"
  previous="$SNAPSHOT_PREVIOUS_BASE/data/$domain/$entry"
  require_cmd rsync

  if [[ "$ACTIVE_REMOTE_TYPE" == 'ssh' ]]; then
    remote_exec_script '
set -eu
stage=$1; destination=$2
case "$stage" in */snapshots/.staging-*) ;; *) exit 65 ;; esac
[ -d "$stage" ] && [ ! -L "$stage" ]
data="$stage/data"; domain_root=${destination%/*}
[ -d "$data" ] && [ ! -L "$data" ]
[ -d "$domain_root" ] && [ ! -L "$domain_root" ]
rm -rf -- "$destination"
mkdir -p -- "$destination"
[ -d "$destination" ] && [ ! -L "$destination" ]
' "$SNAPSHOT_STAGE" "$destination" || die "Could not stage snapshot entry '$domain/$entry'."
    if [[ -n "$SNAPSHOT_PREVIOUS_BASE" ]] \
      && remote_exec_script 'set -eu; path=$1; [ -d "$path" ] && [ ! -L "$path" ]' "$previous"; then
      has_previous='true'
    fi
    remote_lock_verify
  else
    [[ -d "$SNAPSHOT_STAGE/data" && ! -L "$SNAPSHOT_STAGE/data" \
      && -d "$SNAPSHOT_STAGE/data/$domain" && ! -L "$SNAPSHOT_STAGE/data/$domain" ]] \
      || die "Unsafe structured snapshot domain: $domain"
    rm -rf -- "$destination"
    mkdir -p -- "$destination"
    if [[ -n "$SNAPSHOT_PREVIOUS_BASE" && -d "$previous" && ! -L "$previous" ]]; then
      has_previous='true'
    fi
  fi
  [[ "$has_previous" != 'true' ]] || options+=("--link-dest=$previous")
  if [[ "$ACTIVE_REMOTE_TYPE" == 'ssh' ]]; then
    options+=(--protect-args -e "ssh -p $SSH_PORT -o ControlPath=$SSH_CONTROL_PATH")
    destination_argument="${SSH_TARGET}:${destination}/"
  else
    destination_argument="$destination/"
  fi
  rsync "${options[@]}" -- "$source/" "$destination_argument" \
    || die "Could not snapshot structured entry '$domain/$entry'."
  remote_lock_verify
}

# Synchronize a locally assembled structured domain into a fresh staging tree.
# --link-dest points at the immutable previous generation, so unchanged Git
# objects and worktree files are hardlinked without mutating an older snapshot.
snapshot_sync_domain_tree() {
  local source="$1" domain="$2" destination destination_argument previous
  local has_previous='false'
  local -a options=(--archive --delete --human-readable --itemize-changes)

  validate_safe_name "$domain" || die "Invalid snapshot domain: $domain"
  [[ -d "$source" && ! -L "$source" ]] || die "Unsafe structured snapshot source: $source"
  [[ -n "$SNAPSHOT_STAGE" ]] || die 'No snapshot is being staged.'
  require_cmd rsync
  destination="$SNAPSHOT_STAGE/data/$domain/"
  previous="$SNAPSHOT_PREVIOUS_BASE/data/$domain"
  if [[ -n "$SNAPSHOT_PREVIOUS_BASE" ]]; then
    if [[ "$ACTIVE_REMOTE_TYPE" == 'ssh' ]]; then
      if remote_exec_script 'set -eu; path=$1; [ -d "$path" ] && [ ! -L "$path" ]' "$previous"; then
        has_previous='true'
      fi
      remote_lock_verify
    elif [[ -d "$previous" && ! -L "$previous" ]]; then
      has_previous='true'
    fi
  fi
  [[ "$has_previous" != 'true' ]] || options+=("--link-dest=$previous")
  if [[ "$ACTIVE_REMOTE_TYPE" == 'ssh' ]]; then
    options+=(--protect-args -e "ssh -p $SSH_PORT -o ControlPath=$SSH_CONTROL_PATH")
    destination_argument="${SSH_TARGET}:${destination}"
  else
    destination_argument="$destination"
  fi
  rsync "${options[@]}" -- "$source/" "$destination_argument" \
    || die "Could not snapshot structured domain '$domain'."
  remote_lock_verify
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
  remote_assert_mirror_path "$path" leaf
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
  local path="$1" dry_run="$2" relative source asserted_source source_argument
  local -a options=(--archive --relative --no-implied-dirs --human-readable --itemize-changes)
  relative="${path#/}"
  source="$SNAPSHOT_BASE/data/$SNAPSHOT_RESTORE_DOMAIN/root/./$relative"
  asserted_source="$SNAPSHOT_BASE/data/$SNAPSHOT_RESTORE_DOMAIN/root/$relative"
  validate_absolute_path "$path" || die "Unsafe restore path: $path"
  validate_safe_name "$SNAPSHOT_RESTORE_DOMAIN" || die 'Invalid restore domain.'
  require_cmd rsync
  remote_assert_mirror_path "$asserted_source" leaf
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

# Download one stable-ID entry from a structured domain before local parsing or
# Git operations. Backup targets remain inert data stores, including over SSH.
snapshot_download_domain_entry() {
  local domain="$1" entry="$2" destination="$3" source source_argument
  local -a options=(--archive --delete --human-readable --itemize-changes)

  validate_safe_name "$domain" || die "Invalid snapshot domain: $domain"
  validate_safe_name "$entry" || die "Invalid snapshot entry: $entry"
  [[ -d "$destination" && ! -L "$destination" ]] \
    || die "Unsafe snapshot download destination: $destination"
  source="$SNAPSHOT_BASE/data/$domain/$entry"
  require_cmd rsync
  remote_assert_mirror_path "$source" directory
  if [[ "$ACTIVE_REMOTE_TYPE" == 'ssh' ]]; then
    remote_exec_script 'set -eu; path=$1; [ -d "$path" ] && [ ! -L "$path" ]' "$source" \
      || die "Snapshot entry is missing or unsafe: $domain/$entry"
    options+=(--protect-args -e "ssh -p $SSH_PORT -o ControlPath=$SSH_CONTROL_PATH")
    source_argument="${SSH_TARGET}:${source}/"
  else
    [[ -d "$source" && ! -L "$source" ]] \
      || die "Snapshot entry is missing or unsafe: $domain/$entry"
    source_argument="$source/"
  fi
  rsync "${options[@]}" -- "$source_argument" "$destination/" \
    || die "Could not download snapshot entry '$domain/$entry'."
  remote_lock_verify
}
