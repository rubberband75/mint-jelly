#!/usr/bin/env bash

backup_plugin_firefox_is_running() {
  local user_id

  # Silently treating a missing process inspector as "not running" could
  # produce an inconsistent live-profile backup.
  require_cmd pgrep
  user_id="$(id -u)"
  pgrep -u "$user_id" -x firefox >/dev/null 2>&1 \
    || pgrep -u "$user_id" -x firefox-bin >/dev/null 2>&1
}

backup_plugin_firefox_choose_running_action() {
  local answer confirmation

  FIREFOX_BACKUP_ACTION='skip'
  while true; do
    cat <<'EOF'

Firefox is currently running and may be writing to its profile databases.
Copying them now can produce a backup whose files do not agree with each other.

  1) Skip Firefox for this run (recommended)
     Back up everything else and keep the most recent stored Firefox copy.

  2) Back up Firefox without closing it (unsafe)
     The copied profile may be inconsistent and may not restore correctly.

  3) Close Firefox, then retry its backup
     Pause while you close every Firefox window, then verify Firefox has stopped.

EOF
    printf 'Choose an action [1]: '
    if ! IFS= read -r answer; then
      warn 'No selection was read; skipping Firefox safely.'
      return 0
    fi
    [[ -n "$answer" ]] || answer='1'

    case "$answer" in
      1)
        FIREFOX_BACKUP_ACTION='skip'
        return 0
        ;;
      2)
        FIREFOX_BACKUP_ACTION='copy-unsafe'
        return 0
        ;;
      3)
        printf 'Close every Firefox window, then press Enter to recheck: '
        if ! IFS= read -r confirmation; then
          warn 'No confirmation was read; skipping Firefox safely.'
          return 0
        fi
        if backup_plugin_firefox_is_running; then
          warn 'Firefox is still running. Choose how to continue.'
        else
          FIREFOX_BACKUP_ACTION='copy-safe'
          return 0
        fi
        ;;
      *)
        warn 'Enter 1, 2, or 3.'
        ;;
    esac
  done
}

backup_plugin_firefox_prepare() {
  local xdg_config_home roots root
  local -a candidates=() existing_roots=()

  xdg_config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
  roots="${FIREFOX_PROFILE_ROOTS:-${xdg_config_home}/mozilla/firefox:$HOME/.mozilla/firefox:$HOME/snap/firefox/common/.mozilla/firefox:$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox}"
  IFS=: read -r -a candidates <<< "$roots"

  for root in "${candidates[@]}"; do
    [[ -d "$root" ]] || continue
    existing_roots+=("$root")
  done

  (( ${#existing_roots[@]} > 0 )) || return 0
  if backup_plugin_firefox_is_running; then
    if is_interactive; then
      backup_plugin_firefox_choose_running_action
    else
      FIREFOX_BACKUP_ACTION='skip'
    fi

    case "$FIREFOX_BACKUP_ACTION" in
      skip)
        for root in "${existing_roots[@]}"; do
          backup_plugin_retain_source "$root"
        done
        warn 'Firefox is running; skipping its profiles for this backup. The most recent stored Firefox copy will be retained when available.'
        return 0
        ;;
      copy-unsafe)
        warn 'Unsafe choice selected: copying live Firefox profiles. This backup may be inconsistent and should not be your only recovery copy.'
        ;;
      copy-safe) ;;
      *) die "Unknown Firefox backup action: $FIREFOX_BACKUP_ACTION" ;;
    esac
  fi

  for root in "${existing_roots[@]}"; do
    backup_plugin_add_source "$root"
  done
}

restore_plugin_firefox_preflight() {
  local xdg_config_home roots root
  local restores_firefox='false'
  local -a candidates=()

  xdg_config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
  roots="${FIREFOX_PROFILE_ROOTS:-${xdg_config_home}/mozilla/firefox:$HOME/.mozilla/firefox:$HOME/snap/firefox/common/.mozilla/firefox:$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox}"
  IFS=: read -r -a candidates <<< "$roots"
  for root in "${candidates[@]}"; do
    if restore_path_is_included "$root"; then
      restores_firefox='true'
      break
    fi
  done

  if [[ "$restores_firefox" == 'true' ]] && backup_plugin_firefox_is_running; then
    die 'Firefox is running. Exit Firefox completely before restoring its profiles.'
  fi
}

register_backup_plugin \
  firefox \
  backup_plugin_firefox_prepare \
  restore_plugin_firefox_preflight
