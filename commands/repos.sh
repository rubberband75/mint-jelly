#!/usr/bin/env bash

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/repositories.sh"

usage() {
  cat <<'EOF'
Usage:
  mint-jelly repos add NAME PATH
  mint-jelly repos remove NAME
  mint-jelly repos include NAME PATH...
  mint-jelly repos exclude NAME PATH...
  mint-jelly repos uninclude NAME PATH...
  mint-jelly repos unexclude NAME PATH...
  mint-jelly repos list
  mint-jelly repos config
  mint-jelly repos list-remote [--remote NAME] [--source-host HOSTNAME]
  mint-jelly repos backup [NAME...] [--remote NAME] [--dry-run]
  mint-jelly repos restore [NAME...] [restore options]

Repository include and exclude paths are literal paths relative to the
repository root. Include is intended for ignored local state such as .env and
.vscode. The .git directory can never be included.
EOF
}

repository_normalize_root() {
  local input="$1" resolved root

  require_cmd git
  require_cmd realpath
  if [[ "$input" == '~/'* ]]; then
    input="$HOME/${input:2}"
  fi
  resolved="$(realpath -e -- "$input" 2>/dev/null)" \
    || die "Repository path does not exist: $1"
  [[ -d "$resolved" ]] || die "Repository path is not a directory: $1"
  validate_absolute_path "$resolved" || die "Unsafe repository path: $1"
  [[ "$(git -C "$resolved" rev-parse --is-bare-repository 2>/dev/null || true)" == 'false' ]] \
    || die "Path is not a Git worktree: $1"
  root="$(git -C "$resolved" rev-parse --show-toplevel 2>/dev/null)" \
    || die "Path is not a Git worktree: $1"
  root="$(realpath -e -- "$root")" || die "Could not resolve Git root: $root"
  [[ "$resolved" == "$root" ]] \
    || die "Configure the repository root, not a path inside it: $root"

  if [[ "$resolved" == "$HOME/"* ]]; then
    printf '~/%s\n' "${resolved#"$HOME/"}"
  else
    printf '%s\n' "$resolved"
  fi
}

repository_require_name() {
  validate_safe_name "$1" || die "Invalid repository name: $1"
}

repository_require_configured() {
  repository_require_name "$1"
  repository_exists "$1" || die "Repository '$1' is not configured."
}

repository_add() {
  local name="$1" path="$2"

  repository_require_name "$name"
  path="$(repository_normalize_root "$path")"
  local_operation_lock_acquire
  trap local_operation_lock_release EXIT
  config_initialize_if_missing
  config_read
  repository_exists "$name" && die "Repository '$name' is already configured."
  config_add_repository_name "$name"
  REPOSITORY_PATH["$name"]="$path"
  config_write
  local_operation_lock_release
  trap - EXIT
  log "Added repository '$name': $path"
}

repository_remove() {
  local name="$1"

  repository_require_name "$name"
  local_operation_lock_acquire
  trap local_operation_lock_release EXIT
  require_initialized_config
  config_read
  repository_exists "$name" || die "Repository '$name' is not configured."
  config_remove_repository "$name"
  config_write
  repository_remove_cached_mirror "$name"
  local_operation_lock_release
  trap - EXIT
  log "Removed repository '$name' from the recovery plan."
}

repository_add_rules() {
  local kind="$1" name="$2" path other changed='false'
  local map_name opposite_map
  local -a opposite_values=()
  shift 2

  [[ "$kind" == 'include' ]] \
    && { map_name='REPOSITORY_INCLUDES'; opposite_map='REPOSITORY_EXCLUDES'; } \
    || { map_name='REPOSITORY_EXCLUDES'; opposite_map='REPOSITORY_INCLUDES'; }
  local_operation_lock_acquire
  trap local_operation_lock_release EXIT
  require_initialized_config
  config_read
  repository_require_configured "$name"
  config_repository_get_values "$opposite_map" "$name" opposite_values
  for path in "$@"; do
    validate_repository_relative_path "$path" \
      || die "Unsafe repository-relative path: $path"
    config_repository_value_exists "$map_name" "$name" "$path" && continue
    for other in "${opposite_values[@]}"; do
      config_repository_rules_overlap "$path" "$other" \
        && die "Repository '$name' has conflicting include/exclude paths: $path and $other"
    done
    config_repository_append_value "$map_name" "$name" "$path"
    changed='true'
  done
  if [[ "$changed" == 'true' ]]; then
    config_write
    [[ "$kind" != 'include' ]] \
      || warn "Repository '$name' includes may contain secrets; protect the backup destination accordingly."
  fi
  local_operation_lock_release
  trap - EXIT
  log "Updated $kind paths for repository '$name'."
}

repository_remove_rules() {
  local kind="$1" name="$2" path changed='false' map_name
  shift 2

  [[ "$kind" == 'include' ]] \
    && map_name='REPOSITORY_INCLUDES' \
    || map_name='REPOSITORY_EXCLUDES'
  local_operation_lock_acquire
  trap local_operation_lock_release EXIT
  require_initialized_config
  config_read
  repository_require_configured "$name"
  for path in "$@"; do
    validate_repository_relative_path "$path" \
      || die "Unsafe repository-relative path: $path"
    if config_repository_remove_value "$map_name" "$name" "$path"; then
      changed='true'
    fi
  done
  [[ "$changed" != 'true' ]] || config_write
  local_operation_lock_release
  trap - EXIT
  log "Updated $kind paths for repository '$name'."
}

repository_list() {
  local name value
  local -a values=()

  if [[ ! -f "$MINT_JELLY_CONFIG_FILE" ]]; then
    printf 'No repositories configured.\n'
    return 0
  fi
  config_read
  if (( ${#REPOSITORY_NAMES[@]} == 0 )); then
    printf 'No repositories configured.\n'
    return 0
  fi
  for name in "${REPOSITORY_NAMES[@]}"; do
    printf '%s\t%s\n' "$name" "${REPOSITORY_PATH[$name]}"
    config_repository_get_includes "$name" values
    for value in "${values[@]}"; do printf '\tinclude\t%s\n' "$value"; done
    config_repository_get_excludes "$name" values
    for value in "${values[@]}"; do printf '\texclude\t%s\n' "$value"; done
  done
}

repository_backup() {
  local name
  local -a names=() forwarded=(--domain repositories)

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --remote)
        [[ $# -ge 2 ]] || die '--remote requires a name.'
        forwarded+=(--remote "$2")
        shift 2
        ;;
      --dry-run) forwarded+=("$1"); shift ;;
      -h|--help) usage; return 0 ;;
      --*) die "Unknown repos backup argument: $1" ;;
      *) repository_require_name "$1"; names+=("$1"); shift ;;
    esac
  done
  if (( ${#names[@]} > 0 )); then
    require_initialized_config
    config_read
    for name in "${names[@]}"; do
      repository_exists "$name" || die "Repository '$name' is not configured."
      forwarded+=(--repository "$name")
    done
  fi
  MINT_JELLY_COMMAND='mint-jelly repos backup' exec "$SCRIPT_DIR/backup.sh" "${forwarded[@]}"
}

repository_restore() {
  local -a forwarded=(--domain repositories)

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --remote|--source-host)
        [[ $# -ge 2 ]] || die "$1 requires a value."
        forwarded+=("$1" "$2")
        shift 2
        ;;
      --dry-run|--yes|--force|--include-hardware|--allow-platform-mismatch|--allow-weak-verification)
        forwarded+=("$1")
        shift
        ;;
      -h|--help) usage; return 0 ;;
      --*) die "Unknown repos restore argument: $1" ;;
      *)
        repository_require_name "$1"
        forwarded+=(--repository "$1")
        shift
        ;;
    esac
  done
  MINT_JELLY_COMMAND='mint-jelly repos restore' exec "$SCRIPT_DIR/restore.sh" "${forwarded[@]}"
}

repository_list_remote() {
  local -a forwarded=(--domain repositories --list)

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --remote|--source-host)
        [[ $# -ge 2 ]] || die "$1 requires a value."
        forwarded+=("$1" "$2")
        shift 2
        ;;
      -h|--help) usage; return 0 ;;
      *) die "Unknown repos list-remote argument: $1" ;;
    esac
  done
  MINT_JELLY_COMMAND='mint-jelly repos list-remote' exec "$SCRIPT_DIR/restore.sh" "${forwarded[@]}"
}

action="${1-}"
[[ -z "$action" ]] || shift
case "$action" in
  add)
    [[ $# -eq 2 ]] || die 'repos add requires NAME and PATH.'
    repository_add "$1" "$2"
    ;;
  remove)
    [[ $# -eq 1 ]] || die 'repos remove requires exactly one NAME.'
    repository_remove "$1"
    ;;
  include|exclude)
    (( $# >= 2 )) || die "repos $action requires NAME and at least one PATH."
    name="$1"
    shift
    repository_add_rules "$action" "$name" "$@"
    ;;
  uninclude|unexclude)
    (( $# >= 2 )) || die "repos $action requires NAME and at least one PATH."
    name="$1"
    shift
    kind="${action#un}"
    repository_remove_rules "$kind" "$name" "$@"
    ;;
  list)
    [[ $# -eq 0 ]] || die 'repos list does not accept arguments.'
    repository_list
    ;;
  config)
    [[ $# -eq 0 ]] || die 'repos config does not accept arguments.'
    config_initialize_if_missing
    printf 'Configured repositories:\n'
    repository_list
    printf '\nUse repos add/remove/include/exclude/uninclude/unexclude to change this recovery plan.\n'
    ;;
  backup) repository_backup "$@" ;;
  restore) repository_restore "$@" ;;
  list-remote) repository_list_remote "$@" ;;
  -h|--help|'') usage ;;
  *) die "Unknown repos command: $action" ;;
esac
