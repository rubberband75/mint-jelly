#!/usr/bin/env bash

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/remote.sh"
source "$SCRIPT_DIR/lib/recovery.sh"
source "$SCRIPT_DIR/lib/plans.sh"
source "$SCRIPT_DIR/lib/checklist.sh"

usage() {
  cat <<'EOF'
Usage:
  mint-jelly flatpak install [--user | --system] REMOTE APP_ID... [--yes]
  mint-jelly flatpak add [--user | --system] REMOTE APP_ID...
  mint-jelly flatpak remove APP_ID...
  mint-jelly flatpak list
  mint-jelly flatpak config
  mint-jelly flatpak backup [--remote NAME]
  mint-jelly flatpak list-remote [--remote NAME] [--source-host HOSTNAME]
  mint-jelly flatpak restore [--remote NAME] [--source-host HOSTNAME]
      [--dry-run] [--yes] [--allow-platform-mismatch]

The default installation scope is --user. add and remove only change the
recovery plan; they never install or uninstall applications.
EOF
}

array_has() {
  local expected="$1" value
  shift
  for value in "$@"; do
    [[ "$value" == "$expected" ]] && return 0
  done
  return 1
}

flatpak_ref_for() {
  local scope="$1" remote="$2" app="$3" mode="$4"
  local ref
  local -a scope_flag=("--$scope")

  if [[ "$mode" == 'installed' ]]; then
    ref="$(flatpak info "${scope_flag[@]}" --show-ref "$app" 2>/dev/null || true)"
  else
    ref="$(flatpak remote-info "${scope_flag[@]}" --show-ref "$remote" "$app" 2>/dev/null || true)"
  fi
  [[ "$ref" =~ ^app/${app//./\.}/[^/]+/([A-Za-z0-9][A-Za-z0-9._-]*)$ ]] \
    || die "Could not resolve a canonical Flatpak ref for '$app' from '$remote'."
  printf '%s|%s|%s|%s' "$scope" "$remote" "$app" "${BASH_REMATCH[1]}"
}

flatpak_spec_parts() {
  local spec="$1"
  IFS='|' read -r SPEC_SCOPE SPEC_REMOTE SPEC_APP SPEC_BRANCH <<< "$spec"
}

flatpak_spec_is_installed() {
  local spec="$1" ref
  flatpak_spec_parts "$spec"
  ref="$(flatpak info "--$SPEC_SCOPE" --show-ref "$SPEC_APP" 2>/dev/null || true)"
  [[ "$ref" == app/"$SPEC_APP"/*/"$SPEC_BRANCH" ]]
}

track_flatpak() {
  local spec="$1" existing changed='false'
  local -a retained=()
  flatpak_spec_parts "$spec"
  for existing in "${FLATPAK_APPS[@]}"; do
    IFS='|' read -r existing_scope _ existing_app _ <<< "$existing"
    if [[ "$existing_scope" == "$SPEC_SCOPE" && "$existing_app" == "$SPEC_APP" ]]; then
      [[ "$existing" == "$spec" ]] || changed='true'
      continue
    fi
    retained+=("$existing")
  done
  if ! array_has "$spec" "${FLATPAK_APPS[@]}"; then
    retained+=("$spec")
    changed='true'
  else
    retained+=("$spec")
  fi
  FLATPAK_APPS=("${retained[@]}")
  if [[ "$changed" == 'true' ]]; then
    config_write
    log "Tracked Flatpak application '$SPEC_APP' in the $SPEC_SCOPE scope."
  fi
}

flatpak_install_spec() {
  local spec="$1" assume_yes="$2"
  local -a command
  flatpak_spec_parts "$spec"
  flatpak_spec_is_installed "$spec" && return 0
  command=(flatpak install "--$SPEC_SCOPE")
  [[ "$assume_yes" != 'true' ]] || command+=(--noninteractive)
  command+=("$SPEC_REMOTE" "$SPEC_APP//$SPEC_BRANCH")
  "${command[@]}" || die "Flatpak installation failed for '$SPEC_APP'."
  flatpak_spec_is_installed "$spec" \
    || die "Flatpak reported success, but '$SPEC_APP//$SPEC_BRANCH' is not installed."
}

configure_flatpaks() {
  local scope remote app branch spec detail status query_scope query_output
  local -a candidates=("${FLATPAK_APPS[@]}")

  require_cmd flatpak
  for query_scope in user system; do
    if ! query_output="$(
      flatpak list "--$query_scope" --app \
        --columns=installation,origin,application,branch 2>&1
    )"; then
      warn "Could not list $query_scope Flatpak applications: $query_output"
      continue
    fi
    while IFS=$'\t' read -r scope remote app branch; do
      [[ -n "$scope" && -n "$remote" && -n "$app" && -n "$branch" ]] || continue
      spec="$scope|$remote|$app|$branch"
      validate_flatpak_app_spec "$spec" || continue
      array_has "$spec" "${candidates[@]}" || candidates+=("$spec")
    done <<< "$query_output"
  done

  CHECKLIST_IDS=("${candidates[@]}")
  CHECKLIST_LABELS=()
  CHECKLIST_DETAILS=()
  CHECKLIST_INITIAL_SELECTED=()
  for spec in "${candidates[@]}"; do
    flatpak_spec_parts "$spec"
    CHECKLIST_LABELS+=("$SPEC_APP")
    detail="$SPEC_SCOPE, $SPEC_REMOTE, branch $SPEC_BRANCH"
    if flatpak_spec_is_installed "$spec"; then
      detail+=' [installed]'
    else
      detail+=' [not installed]'
    fi
    if array_has "$spec" "${FLATPAK_APPS[@]}"; then
      detail+=' [configured]'
      CHECKLIST_INITIAL_SELECTED+=(1)
    else
      CHECKLIST_INITIAL_SELECTED+=(0)
    fi
    CHECKLIST_DETAILS+=("$detail")
  done
  CHECKLIST_TITLE='Select Flatpak applications for recovery'
  CHECKLIST_NOTE='Only applications are tracked; runtimes and dependencies are excluded.'
  if checklist_run; then
    FLATPAK_APPS=("${CHECKLIST_RESULT[@]}")
    config_write
    log "Configured ${#FLATPAK_APPS[@]} Flatpak application(s)."
  else
    status=$?
    (( status == 1 )) || return "$status"
    log 'Flatpak configuration unchanged.'
  fi
}

select_remote() {
  local requested="$1"
  if [[ -n "$requested" ]]; then
    remote_exists "$requested" || die "Unknown backup remote: $requested"
    printf '%s' "$requested"
  else
    [[ -n "$DEFAULT_REMOTE" ]] \
      || die 'No default remote is configured. Run: mint-jelly config remote add'
    printf '%s' "$DEFAULT_REMOTE"
  fi
}

write_remote_plan() {
  local requested="$1" selected hostname temporary
  selected="$(select_remote "$requested")"
  hostname="$(hostname)"
  temporary="$(mktemp "$MINT_JELLY_CONFIG_DIR/.flatpak-plan.XXXXXX")"
  plan_reset
  PLAN_KIND='flatpak'
  plan_populate_platform "$hostname"
  PLAN_ENTRIES=("${FLATPAK_APPS[@]}")
  plan_write_file "$temporary"
  trap 'rm -f -- "$temporary"; remote_close; local_operation_lock_release' EXIT
  remote_open "$selected" "$hostname"
  remote_lock_acquire exclusive
  remote_write_manifest flatpak "$temporary" "$PLAN_MAX_BYTES"
  remote_lock_release || die 'Could not release the remote operation lock.'
  remote_close
  rm -f -- "$temporary"
  trap - EXIT
  local_operation_lock_release
  log "Backed up ${#FLATPAK_APPS[@]} Flatpak application(s) to remote '$selected'."
}

read_remote_plan() {
  local requested="$1" source_host="$2" selected temporary
  selected="$(select_remote "$requested")"
  [[ -n "$source_host" ]] || source_host="$(hostname)"
  validate_safe_name "$source_host" || die "Unsafe source hostname: $source_host"
  temporary="$(mktemp "$MINT_JELLY_CONFIG_DIR/.flatpak-plan.XXXXXX")"
  PLAN_TEMP="$temporary"
  remote_open "$selected" "$source_host" read
  remote_lock_acquire shared
  remote_read_manifest flatpak "$PLAN_MAX_BYTES" > "$temporary" \
    || die "No Flatpak manifest exists for '$source_host'."
  remote_lock_release || die 'Could not release the remote operation lock.'
  remote_close
  plan_read "$temporary"
  rm -f -- "$temporary"
  PLAN_TEMP=''
  [[ "$PLAN_KIND" == 'flatpak' ]] || die 'Remote manifest has the wrong domain.'
  [[ "$PLAN_HOSTNAME" == "$source_host" ]] || die 'Remote manifest hostname does not match the requested host.'
  SELECTED_REMOTE_RESULT="$selected"
  SOURCE_HOST_RESULT="$source_host"
}

print_specs() {
  local spec
  for spec in "$@"; do
    flatpak_spec_parts "$spec"
    printf '%s\t%s\t%s\t%s\n' "$SPEC_APP" "$SPEC_SCOPE" "$SPEC_REMOTE" "$SPEC_BRANCH"
  done
}

confirm_restore() {
  local answer
  [[ "$1" == 'true' ]] && return 0
  is_interactive || die 'Flatpak restore requires confirmation; use --yes after reviewing the plan.'
  printf 'Restore this Flatpak application plan? [y/N]: '
  IFS= read -r answer
  [[ "${answer,,}" == 'y' || "${answer,,}" == 'yes' ]] || die 'Flatpak restore cancelled.'
}

main() {
  local action="${1-}" scope='user' requested_remote='' source_host=''
  local dry_run='false' assume_yes='false' allow_mismatch='false'
  local remote app spec existing keep
  local -a apps=() retained=() missing=()

  [[ -n "$action" ]] && shift || true
  case "$action" in
    install|add)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --user) scope='user' ;;
          --system) scope='system' ;;
          --yes) assume_yes='true' ;;
          -h|--help) usage; return 0 ;;
          --*) die "Unknown flatpak $action argument: $1" ;;
          *) apps+=("$1") ;;
        esac
        shift
      done
      (( ${#apps[@]} >= 2 )) || die "flatpak $action requires a remote and at least one application ID."
      remote="${apps[0]}"
      apps=("${apps[@]:1}")
      validate_safe_name "$remote" || die "Invalid Flatpak remote name: $remote"
      require_cmd flatpak
      local_operation_lock_acquire
      trap local_operation_lock_release EXIT
      config_initialize_if_missing
      config_read
      for app in "${apps[@]}"; do
        validate_safe_name "$app" || die "Invalid Flatpak application ID: $app"
        spec="$(flatpak_ref_for "$scope" "$remote" "$app" remote)"
        if [[ "$action" == 'install' ]]; then
          flatpak_install_spec "$spec" "$assume_yes"
          spec="$(flatpak_ref_for "$scope" "$remote" "$app" installed)"
        fi
        track_flatpak "$spec"
      done
      local_operation_lock_release
      trap - EXIT
      ;;
    remove)
      (( $# > 0 )) || die 'flatpak remove requires at least one application ID.'
      local_operation_lock_acquire
      trap local_operation_lock_release EXIT
      config_initialize_if_missing
      config_read
      for app in "$@"; do
        validate_safe_name "$app" || die "Invalid Flatpak application ID: $app"
        found='false'
        retained=()
        for existing in "${FLATPAK_APPS[@]}"; do
          IFS='|' read -r _ _ existing_app _ <<< "$existing"
          if [[ "$existing_app" == "$app" ]]; then found='true'; else retained+=("$existing"); fi
        done
        [[ "$found" == 'true' ]] || die "Flatpak application is not configured: $app"
        FLATPAK_APPS=("${retained[@]}")
      done
      config_write
      local_operation_lock_release
      trap - EXIT
      ;;
    list)
      [[ $# -eq 0 ]] || die 'flatpak list does not accept arguments.'
      [[ -f "$MINT_JELLY_CONFIG_FILE" ]] || { printf 'No Flatpak applications configured.\n'; return 0; }
      config_read
      (( ${#FLATPAK_APPS[@]} > 0 )) || { printf 'No Flatpak applications configured.\n'; return 0; }
      print_specs "${FLATPAK_APPS[@]}"
      ;;
    config)
      [[ $# -eq 0 ]] || die 'flatpak config does not accept arguments.'
      local_operation_lock_acquire
      trap local_operation_lock_release EXIT
      config_initialize_if_missing
      config_read
      configure_flatpaks
      local_operation_lock_release
      trap - EXIT
      ;;
    backup)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --remote) [[ $# -ge 2 ]] || die '--remote requires a name.'; requested_remote="$2"; shift ;;
          -h|--help) usage; return 0 ;;
          *) die "Unknown flatpak backup argument: $1" ;;
        esac
        shift
      done
      require_initialized_config
      local_operation_lock_acquire
      config_read
      write_remote_plan "$requested_remote"
      ;;
    list-remote|restore)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --remote) [[ $# -ge 2 ]] || die '--remote requires a name.'; requested_remote="$2"; shift ;;
          --source-host) [[ $# -ge 2 ]] || die '--source-host requires a hostname.'; source_host="$2"; shift ;;
          --dry-run) dry_run='true' ;;
          --yes) assume_yes='true' ;;
          --allow-platform-mismatch) allow_mismatch='true' ;;
          -h|--help) usage; return 0 ;;
          *) die "Unknown flatpak $action argument: $1" ;;
        esac
        shift
      done
      [[ "$action" == 'restore' || ( "$dry_run" == 'false' && "$assume_yes" == 'false' \
        && "$allow_mismatch" == 'false' ) ]] \
        || die 'flatpak list-remote accepts only --remote and --source-host.'
      require_initialized_config
      require_cmd flatpak
      local_operation_lock_acquire
      trap '[[ -z "${PLAN_TEMP:-}" ]] || rm -f -- "$PLAN_TEMP"; remote_close; local_operation_lock_release' EXIT
      config_read
      read_remote_plan "$requested_remote" "$source_host"
      printf 'Flatpak plan from %s/%s, recorded %s:\n' \
        "$SELECTED_REMOTE_RESULT" "$SOURCE_HOST_RESULT" "$PLAN_CREATED_AT"
      print_specs "${PLAN_ENTRIES[@]}"
      [[ "$action" == 'restore' ]] || return 0
      if ! plan_platform_matches_current "$(hostname)" && [[ "$allow_mismatch" != 'true' ]]; then
        die 'Refusing Flatpak restore from a different platform; use --allow-platform-mismatch after reviewing it.'
      fi
      for spec in "${PLAN_ENTRIES[@]}"; do
        flatpak_spec_is_installed "$spec" || missing+=("$spec")
      done
      printf 'Missing applications: %d\n' "${#missing[@]}"
      [[ "$dry_run" == 'false' ]] || { log 'Dry run complete; no configuration or applications were changed.'; return 0; }
      confirm_restore "$assume_yes"
      FLATPAK_APPS=("${PLAN_ENTRIES[@]}")
      config_write
      for spec in "${missing[@]}"; do
        flatpak_install_spec "$spec" "$assume_yes"
      done
      log 'Flatpak restore completed successfully.'
      ;;
    -h|--help|'') usage ;;
    *) die "Unknown flatpak command: $action" ;;
  esac
}

main "$@"
