#!/usr/bin/env bash

BACKUP_PLUGIN_SOURCES=()
BACKUP_PLUGIN_RETAINED_SOURCES=()
BACKUP_PLUGIN_NAMES=()
declare -Ag BACKUP_PLUGIN_PREPARE_FUNCTION=()
declare -Ag RESTORE_PLUGIN_PREFLIGHT_FUNCTION=()
declare -Ag RESTORE_PLUGIN_APPLY_FUNCTION=()

register_backup_plugin() {
  local name="$1"
  local prepare_function="$2"
  local restore_preflight_function="${3-}"
  local restore_apply_function="${4-}"

  validate_safe_name "$name" || die "Plugin registered an invalid name: $name"
  [[ -z "${BACKUP_PLUGIN_PREPARE_FUNCTION[$name]+set}" ]] \
    || die "Backup plugin registered more than once: $name"
  declare -F "$prepare_function" >/dev/null \
    || die "Backup plugin '$name' registered a missing function: $prepare_function"
  if [[ -n "$restore_preflight_function" ]]; then
    declare -F "$restore_preflight_function" >/dev/null \
      || die "Backup plugin '$name' registered a missing restore preflight function: $restore_preflight_function"
  fi
  if [[ -n "$restore_apply_function" ]]; then
    declare -F "$restore_apply_function" >/dev/null \
      || die "Backup plugin '$name' registered a missing restore apply function: $restore_apply_function"
  fi

  BACKUP_PLUGIN_NAMES+=("$name")
  BACKUP_PLUGIN_PREPARE_FUNCTION["$name"]="$prepare_function"
  RESTORE_PLUGIN_PREFLIGHT_FUNCTION["$name"]="$restore_preflight_function"
  RESTORE_PLUGIN_APPLY_FUNCTION["$name"]="$restore_apply_function"
}

backup_plugin_add_source() {
  local path="$1"

  [[ -e "$path" || -L "$path" ]] || return 0
  validate_absolute_path "$path" \
    || die "Backup plugin discovered an unsafe source path: $path"
  BACKUP_PLUGIN_SOURCES+=("$path")
}

backup_plugin_retain_source() {
  local path="$1"

  [[ -e "$path" || -L "$path" ]] || return 0
  validate_absolute_path "$path" \
    || die "Backup plugin retained an unsafe source path: $path"
  BACKUP_PLUGIN_RETAINED_SOURCES+=("$path")
}

load_backup_plugins() {
  local plugin_file
  local -a plugin_files=()

  BACKUP_PLUGIN_NAMES=()
  BACKUP_PLUGIN_PREPARE_FUNCTION=()
  RESTORE_PLUGIN_PREFLIGHT_FUNCTION=()
  RESTORE_PLUGIN_APPLY_FUNCTION=()
  shopt -s nullglob
  plugin_files=("$SCRIPT_DIR/backup-plugins/"*.sh)
  shopt -u nullglob

  for plugin_file in "${plugin_files[@]}"; do
    # shellcheck disable=SC1090
    source "$plugin_file"
  done
}

require_configured_plugins_available() {
  local name

  for name in "${BACKUP_PLUGINS[@]}"; do
    [[ -n "${BACKUP_PLUGIN_PREPARE_FUNCTION[$name]-}" ]] \
      || die "Unknown backup plugin '$name'. Available plugins: ${BACKUP_PLUGIN_NAMES[*]:-none}"
  done
}

prepare_configured_backup_plugins() {
  local name prepare_function

  require_configured_plugins_available
  BACKUP_PLUGIN_SOURCES=()
  BACKUP_PLUGIN_RETAINED_SOURCES=()
  for name in "${BACKUP_PLUGINS[@]}"; do
    prepare_function="${BACKUP_PLUGIN_PREPARE_FUNCTION[$name]-}"
    "$prepare_function"
  done
}

preflight_configured_restore_plugins() {
  local name preflight_function

  require_configured_plugins_available
  for name in "${BACKUP_PLUGINS[@]}"; do
    preflight_function="${RESTORE_PLUGIN_PREFLIGHT_FUNCTION[$name]-}"
    [[ -n "$preflight_function" ]] || continue
    "$preflight_function"
  done
}

apply_configured_restore_plugins() {
  local name apply_function

  require_configured_plugins_available
  for name in "${BACKUP_PLUGINS[@]}"; do
    apply_function="${RESTORE_PLUGIN_APPLY_FUNCTION[$name]-}"
    [[ -n "$apply_function" ]] || continue
    "$apply_function"
  done
}
