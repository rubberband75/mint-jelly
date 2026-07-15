#!/usr/bin/env bash

backup_plugin_cinnamon_export_dconf() {
  local dconf_path="$1"
  local destination="$2"
  local temporary

  temporary="$(mktemp "${MINT_JELLY_STATE_DIR}/.dconf-export.XXXXXX")"
  if ! dconf dump "$dconf_path" > "$temporary"; then
    rm -f -- "$temporary"
    die "Could not export dconf path: $dconf_path"
  fi
  chmod 0600 -- "$temporary"
  mv -f -- "$temporary" "$destination"
}

backup_plugin_cinnamon_desktop_prepare() {
  local config_home data_home desktop_dir
  local cinnamon_export nemo_export

  require_cmd dconf
  config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
  data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
  mkdir -p -- "$MINT_JELLY_STATE_DIR"
  chmod 0700 -- "$MINT_JELLY_STATE_DIR"

  cinnamon_export="${MINT_JELLY_STATE_DIR}/cinnamon.dconf"
  nemo_export="${MINT_JELLY_STATE_DIR}/nemo-desktop.dconf"
  backup_plugin_cinnamon_export_dconf '/org/cinnamon/' "$cinnamon_export"
  backup_plugin_cinnamon_export_dconf '/org/nemo/desktop/' "$nemo_export"

  # dconf contains the panel topology and Nemo visibility settings. These
  # paths hold per-applet state, installed applet code, icon positions,
  # launcher definitions, display topology, and the Desktop items themselves.
  backup_plugin_add_source "$cinnamon_export"
  backup_plugin_add_source "$nemo_export"
  backup_plugin_add_source "${config_home}/cinnamon"
  backup_plugin_add_source "${config_home}/nemo"
  backup_plugin_add_source "${config_home}/cinnamon-monitors.xml"
  backup_plugin_add_source "${data_home}/cinnamon"
  backup_plugin_add_source "${data_home}/applications"

  if command -v xdg-user-dir >/dev/null 2>&1; then
    desktop_dir="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
  else
    desktop_dir="$HOME/Desktop"
  fi
  if [[ -n "$desktop_dir" && "$desktop_dir" != "$HOME" ]]; then
    backup_plugin_add_source "$desktop_dir"
  fi
}

CINNAMON_RESTORE_CINNAMON_DCONF='false'
CINNAMON_RESTORE_NEMO_DCONF='false'

restore_plugin_cinnamon_desktop_preflight() {
  local remote_state_dir="${ACTIVE_HOST_BASE}/${MINT_JELLY_STATE_DIR#/}"
  local cinnamon_export="${MINT_JELLY_STATE_DIR}/cinnamon.dconf"
  local nemo_export="${MINT_JELLY_STATE_DIR}/nemo-desktop.dconf"

  CINNAMON_RESTORE_CINNAMON_DCONF='false'
  CINNAMON_RESTORE_NEMO_DCONF='false'

  if ! restore_path_is_included "$cinnamon_export"; then
    :
  elif remote_regular_file_exists "${remote_state_dir}/cinnamon.dconf"; then
    CINNAMON_RESTORE_CINNAMON_DCONF='true'
  else
    die 'The manifest includes the Cinnamon dconf export, but the backup file is missing or unsafe.'
  fi

  if ! restore_path_is_included "$nemo_export"; then
    :
  elif remote_regular_file_exists "${remote_state_dir}/nemo-desktop.dconf"; then
    CINNAMON_RESTORE_NEMO_DCONF='true'
  else
    die 'The manifest includes the Nemo desktop dconf export, but the backup file is missing or unsafe.'
  fi

  if [[ "$CINNAMON_RESTORE_CINNAMON_DCONF" == 'true' \
    || "$CINNAMON_RESTORE_NEMO_DCONF" == 'true' ]]; then
    require_cmd dconf
  fi
}

restore_plugin_cinnamon_desktop_apply() {
  local cinnamon_export="${MINT_JELLY_STATE_DIR}/cinnamon.dconf"
  local nemo_export="${MINT_JELLY_STATE_DIR}/nemo-desktop.dconf"

  if [[ "$CINNAMON_RESTORE_CINNAMON_DCONF" == 'true' ]]; then
    [[ -f "$cinnamon_export" && ! -L "$cinnamon_export" ]] \
      || die "Restored Cinnamon dconf export is missing: $cinnamon_export"
    dconf load '/org/cinnamon/' < "$cinnamon_export"
    log 'Applied restored Cinnamon panel and applet settings.'
  fi

  if [[ "$CINNAMON_RESTORE_NEMO_DCONF" == 'true' ]]; then
    [[ -f "$nemo_export" && ! -L "$nemo_export" ]] \
      || die "Restored Nemo dconf export is missing: $nemo_export"
    dconf load '/org/nemo/desktop/' < "$nemo_export"
    log 'Applied restored Nemo desktop settings.'
  fi

  if [[ "$CINNAMON_RESTORE_CINNAMON_DCONF" == 'true' \
    || "$CINNAMON_RESTORE_NEMO_DCONF" == 'true' ]]; then
    log 'Log out and back in if every restored Cinnamon setting is not visible immediately.'
  fi
}

register_backup_plugin \
  cinnamon-desktop \
  backup_plugin_cinnamon_desktop_prepare \
  restore_plugin_cinnamon_desktop_preflight \
  restore_plugin_cinnamon_desktop_apply
