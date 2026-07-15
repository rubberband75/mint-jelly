#!/usr/bin/env bash

# Narrow Cinnamon settings profiles. Each profile owns explicit schema/key
# pairs, so Desktop never captures ~/Desktop and Panel never captures launchers.

SYSTEM_SETTING_IDS=(
  backgrounds effects fonts themes accessibility actions applets date-time
  desklets desktop extensions general gestures hot-corners keyboard languages
  mouse-touchpad night-light notifications panel power preferred-applications
  privacy screensaver sound startup-applications windows workspaces display
)
declare -Ag SYSTEM_SETTING_NAME=(
  [backgrounds]='Backgrounds'
  [effects]='Effects'
  [fonts]='Font Selection'
  [themes]='Themes'
  [accessibility]='Accessibility'
  [actions]='Actions'
  [applets]='Applets'
  [date-time]='Date & Time'
  [desklets]='Desklets'
  [desktop]='Desktop icons and layout'
  [extensions]='Extensions'
  [general]='General'
  [gestures]='Gestures'
  [hot-corners]='Hot Corners'
  [keyboard]='Keyboard'
  [languages]='Languages'
  [mouse-touchpad]='Mouse and Touchpad'
  [night-light]='Night Light'
  [notifications]='Notifications'
  [panel]='Panel'
  [power]='Power Management'
  [preferred-applications]='Preferred Applications'
  [privacy]='Privacy'
  [screensaver]='Screensaver'
  [sound]='Sound'
  [startup-applications]='Startup Applications'
  [windows]='Windows'
  [workspaces]='Workspaces'
  [display]='Display layout'
)
declare -Ag SYSTEM_SETTING_CLASS=()
declare -Ag SYSTEM_SETTING_SCHEMAS=(
  [backgrounds]='org.cinnamon.desktop.background org.cinnamon.desktop.background.slideshow'
  [effects]='org.cinnamon'
  [fonts]='org.cinnamon.desktop.interface org.cinnamon.desktop.wm.preferences org.gnome.desktop.interface'
  [themes]='org.cinnamon.theme org.cinnamon.desktop.interface org.cinnamon.desktop.wm.preferences org.x.apps.portal org.cinnamon.settings-daemon.plugins.xsettings'
  [accessibility]='org.cinnamon.desktop.a11y.applications org.cinnamon.desktop.a11y.keyboard org.cinnamon.desktop.a11y.mouse org.cinnamon.desktop.a11y.magnifier org.cinnamon.keyboard'
  [actions]='org.cinnamon'
  [applets]='org.cinnamon'
  [date-time]='org.cinnamon.desktop.interface org.cinnamon.calendar'
  [desklets]='org.cinnamon'
  [desktop]='org.nemo.desktop'
  [extensions]='org.cinnamon'
  [general]='org.cinnamon org.nemo.preferences'
  [gestures]='org.cinnamon.gestures'
  [hot-corners]='org.cinnamon'
  [keyboard]='org.cinnamon.desktop.keybindings org.cinnamon.desktop.keybindings.wm org.cinnamon.desktop.keybindings.media-keys'
  [languages]=''
  [mouse-touchpad]='org.cinnamon.desktop.peripherals.mouse org.cinnamon.desktop.peripherals.touchpad'
  [night-light]='org.cinnamon.settings-daemon.plugins.color'
  [notifications]='org.cinnamon.desktop.notifications'
  [panel]='org.cinnamon'
  [power]='org.cinnamon.settings-daemon.plugins.power org.cinnamon.desktop.session'
  [preferred-applications]='org.cinnamon.desktop.default-applications.terminal org.cinnamon.desktop.default-applications.calculator org.cinnamon.desktop.media-handling'
  [privacy]='org.cinnamon.desktop.privacy org.cinnamon.desktop.media-handling'
  [screensaver]='org.cinnamon.desktop.screensaver'
  [sound]='org.cinnamon.desktop.sound org.cinnamon.sounds'
  [windows]='org.cinnamon.desktop.wm.preferences org.cinnamon.muffin'
  [workspaces]='org.cinnamon.desktop.wm.preferences org.cinnamon'
)
declare -Ag SYSTEM_SETTING_KEYS=(
  [effects]='desktop-effects desktop-effects-change-size desktop-effects-close desktop-effects-map desktop-effects-minimize desktop-effects-on-dialogs desktop-effects-on-menus desktop-effects-workspace startup-animation enable-vfade window-effect-speed'
  [actions]='enabled-actions'
  [applets]='enabled-applets'
  [desklets]='enabled-desklets'
  [extensions]='enabled-extensions'
  [hot-corners]='hotcorner-layout hotcorner-fullscreen'
  [panel]='panels-enabled panels-autohide panels-height panels-show-delay panels-hide-delay panels-zone-icon-sizes panels-zone-symbolic-icon-sizes panels-zone-text-sizes panel-edit-mode no-adjacent-panel-barriers'
)
declare -Ag SYSTEM_SETTING_PAIRS=(
  [fonts]='org.cinnamon.desktop.interface:font-name org.nemo.desktop:font org.gnome.desktop.interface:document-font-name org.gnome.desktop.interface:monospace-font-name org.cinnamon.desktop.wm.preferences:titlebar-font org.cinnamon.desktop.interface:text-scaling-factor org.cinnamon.settings-daemon.plugins.xsettings:hinting org.cinnamon.settings-daemon.plugins.xsettings:antialiasing org.cinnamon.settings-daemon.plugins.xsettings:rgba-order'
  [themes]='org.cinnamon.theme:name org.cinnamon.desktop.interface:gtk-theme org.cinnamon.desktop.interface:icon-theme org.cinnamon.desktop.interface:cursor-theme org.cinnamon.desktop.wm.preferences:theme org.x.apps.portal:color-scheme org.x.apps.portal:accent-rgb org.cinnamon.settings-daemon.plugins.xsettings:menus-have-icons org.cinnamon.settings-daemon.plugins.xsettings:buttons-have-icons org.cinnamon.desktop.interface:gtk-overlay-scrollbars'
  [date-time]='org.cinnamon.desktop.interface:clock-use-24h org.cinnamon.desktop.interface:clock-show-date org.cinnamon.desktop.interface:clock-show-seconds org.cinnamon.desktop.interface:first-day-of-week'
  [general]='org.cinnamon.muffin:unredirect-fullscreen-windows org.cinnamon.SessionManager:quit-delay-toggle org.cinnamon.SessionManager:quit-time-delay org.cinnamon.launcher:memory-limit-enabled org.cinnamon.launcher:memory-limit org.cinnamon.launcher:check-frequency'
  [keyboard]='org.cinnamon.desktop.peripherals.keyboard:repeat org.cinnamon.desktop.peripherals.keyboard:delay org.cinnamon.desktop.peripherals.keyboard:repeat-interval org.cinnamon.desktop.interface:cursor-blink org.cinnamon.desktop.interface:cursor-blink-time org.cinnamon.desktop.input-sources:sources org.cinnamon.desktop.input-sources:xkb-options org.cinnamon.desktop.keybindings:custom-list'
  [mouse-touchpad]='org.cinnamon.desktop.peripherals.mouse:left-handed org.cinnamon.desktop.peripherals.mouse:natural-scroll org.cinnamon.desktop.peripherals.mouse:locate-pointer org.cinnamon.desktop.peripherals.mouse:middle-click-emulation org.cinnamon.desktop.peripherals.mouse:drag-threshold org.cinnamon.desktop.peripherals.mouse:speed org.cinnamon.desktop.peripherals.mouse:accel-profile org.cinnamon.desktop.peripherals.mouse:double-click org.cinnamon.desktop.interface:gtk-enable-primary-paste org.cinnamon.desktop.interface:cursor-size org.cinnamon.desktop.peripherals.touchpad:send-events org.cinnamon.desktop.peripherals.touchpad:tap-to-click org.cinnamon.desktop.peripherals.touchpad:disable-while-typing org.cinnamon.desktop.peripherals.touchpad:click-method org.cinnamon.desktop.peripherals.touchpad:natural-scroll org.cinnamon.desktop.peripherals.touchpad:speed org.cinnamon.desktop.peripherals.touchpad:two-finger-scrolling-enabled org.cinnamon.desktop.peripherals.touchpad:edge-scrolling-enabled'
  [notifications]='org.cinnamon.desktop.notifications:display-notifications org.cinnamon.desktop.notifications:remove-old org.cinnamon.desktop.notifications:bottom-notifications org.cinnamon.desktop.notifications:notification-screen-display org.cinnamon.desktop.notifications:notification-fixed-screen org.cinnamon.desktop.notifications:fullscreen-notifications org.cinnamon.desktop.notifications:notification-duration org.cinnamon:show-media-keys-osd'
  [workspaces]='org.cinnamon:workspace-osd-visible org.cinnamon.muffin:workspace-cycle org.cinnamon.muffin:workspaces-only-on-primary org.cinnamon:workspace-expo-view-as-grid org.cinnamon:workspace-expo-primary-monitor org.cinnamon:number-workspaces'
)
declare -Ag SYSTEM_SETTING_PAIRS_ONLY=(
  [fonts]=true [themes]=true [date-time]=true [general]=true
  [mouse-touchpad]=true [notifications]=true [workspaces]=true
)
declare -Ag SYSTEM_SETTING_FILES=(
  [backgrounds]='~/.local/share/backgrounds'
  [actions]='~/.local/share/cinnamon/actions'
  [applets]='~/.local/share/cinnamon/applets'
  [desklets]='~/.local/share/cinnamon/desklets'
  [extensions]='~/.local/share/cinnamon/extensions'
  [startup-applications]='~/.config/autostart'
  [preferred-applications]='~/.config/mimeapps.list'
  [languages]='~/.pam_environment ~/.dmrc'
  [display]='~/.config/cinnamon-monitors.xml'
)

system_settings_initialize_classes() {
  local id
  for id in "${SYSTEM_SETTING_IDS[@]}"; do SYSTEM_SETTING_CLASS[$id]='portable'; done
  SYSTEM_SETTING_CLASS[display]='hardware'
  SYSTEM_SETTING_CLASS[mouse-touchpad]='hardware'
  SYSTEM_SETTING_CLASS[panel]='hardware'
  SYSTEM_SETTING_CLASS[power]='hardware'
}
system_settings_initialize_classes

system_setting_exists() {
  [[ -n "${SYSTEM_SETTING_NAME[$1]-}" ]]
}

require_configured_system_settings() {
  local id
  for id in "${SYSTEM_SETTINGS[@]}"; do
    system_setting_exists "$id" || die "Unknown system-settings profile '$id'."
  done
}

system_setting_schema_keys() {
  local profile="$1" schema key filter pair
  if [[ -n "${SYSTEM_SETTING_PAIRS[$profile]-}" ]]; then
    for pair in ${SYSTEM_SETTING_PAIRS[$profile]}; do
      schema="${pair%%:*}"; key="${pair#*:}"
      gsettings list-schemas | grep -Fxq "$schema" || continue
      gsettings list-keys "$schema" | grep -Fxq "$key" || continue
      printf '%s|%s\n' "$schema" "$key"
    done
    [[ "${SYSTEM_SETTING_PAIRS_ONLY[$profile]-false}" != true ]] || return 0
  fi
  filter=" ${SYSTEM_SETTING_KEYS[$profile]-} "
  for schema in ${SYSTEM_SETTING_SCHEMAS[$profile]-}; do
    gsettings list-schemas | grep -Fxq "$schema" || continue
    while IFS= read -r key; do
      if [[ -n "${SYSTEM_SETTING_KEYS[$profile]-}" && "$filter" != *" $key "* ]]; then
        continue
      fi
      printf '%s|%s\n' "$schema" "$key"
    done < <(gsettings list-keys "$schema")
  done
}

system_setting_expand_files() {
  local profile="$1" spec type root directory id config_path existing schema key value uri_path theme_name candidate
  local -a roots=()
  SYSTEM_SETTING_EXPANDED_FILES=()
  for spec in ${SYSTEM_SETTING_FILES[$profile]-}; do
    [[ "$spec" != '~/'* ]] || spec="$HOME/${spec:2}"
    validate_absolute_path "$spec" || die "System-settings profile '$profile' contains an unsafe path."
    [[ -e "$spec" || -L "$spec" ]] && SYSTEM_SETTING_EXPANDED_FILES+=("$spec")
  done
  if [[ "$profile" == backgrounds ]]; then
    for schema in org.cinnamon.desktop.background org.cinnamon.desktop.background.slideshow; do
      for key in picture-uri image-source; do
        gsettings list-schemas | grep -Fxq "$schema" || continue
        gsettings list-keys "$schema" | grep -Fxq "$key" || continue
        value="$(gsettings get "$schema" "$key" 2>/dev/null || true)"
        value="${value#\'}"; value="${value%\'}"
        [[ "$value" == file://* ]] || continue
        if command -v python3 >/dev/null 2>&1; then
          uri_path="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(urllib.parse.urlparse(sys.argv[1]).path))' "$value" 2>/dev/null || true)"
        else
          uri_path="${value#file://}"
        fi
        validate_absolute_path "$uri_path" || continue
        [[ -e "$uri_path" || -L "$uri_path" ]] || continue
        SYSTEM_SETTING_EXPANDED_FILES+=("$uri_path")
      done
    done
  elif [[ "$profile" == themes ]]; then
    while IFS='|' read -r schema key; do
      value="$(gsettings get "$schema" "$key" 2>/dev/null || true)"
      theme_name="${value#\'}"; theme_name="${theme_name%\'}"
      validate_safe_name "$theme_name" || continue
      for candidate in \
        "$HOME/.themes/$theme_name" "$HOME/.local/share/themes/$theme_name" \
        "$HOME/.icons/$theme_name" "$HOME/.local/share/icons/$theme_name"; do
        [[ -e "$candidate" || -L "$candidate" ]] || continue
        for existing in "${SYSTEM_SETTING_EXPANDED_FILES[@]}"; do
          [[ "$existing" != "$candidate" ]] || continue 2
        done
        SYSTEM_SETTING_EXPANDED_FILES+=("$candidate")
      done
    done < <(system_setting_schema_keys themes)
  fi
  case "$profile" in
    actions) type='actions' ;;
    applets) type='applets' ;;
    desklets) type='desklets' ;;
    extensions) type='extensions' ;;
    *) return 0 ;;
  esac
  roots=("$HOME/.local/share/cinnamon/$type" "/usr/share/cinnamon/$type")
  for root in "${roots[@]}"; do
    [[ -d "$root" && ! -L "$root" ]] || continue
    for directory in "$root"/*; do
      [[ -d "$directory" && ! -L "$directory" ]] || continue
      id="${directory##*/}"
      validate_safe_name "$id" || continue
      config_path="${XDG_CONFIG_HOME:-$HOME/.config}/cinnamon/spices/$id"
      [[ -e "$config_path" || -L "$config_path" ]] || continue
      for existing in "${SYSTEM_SETTING_EXPANDED_FILES[@]}"; do
        [[ "$existing" != "$config_path" ]] || continue 2
      done
      SYSTEM_SETTING_EXPANDED_FILES+=("$config_path")
    done
  done
}

system_hardware_fingerprint() {
  local identity='unknown' product='unknown'
  if [[ -r /sys/class/dmi/id/product_uuid ]]; then
    identity="$(tr -cd 'A-Za-z0-9._-' < /sys/class/dmi/id/product_uuid)"
  elif [[ -r /sys/class/dmi/id/product_serial ]]; then
    identity="$(tr -cd 'A-Za-z0-9._-' < /sys/class/dmi/id/product_serial)"
  elif [[ -r /sys/class/dmi/id/board_serial ]]; then
    identity="$(tr -cd 'A-Za-z0-9._-' < /sys/class/dmi/id/board_serial)"
  elif [[ -r /etc/machine-id ]]; then
    # Non-DMI systems have no reinstall-stable identifier. This fallback is
    # intentionally conservative and will require --include-hardware after a
    # clean installation.
    identity="$(tr -cd 'A-Za-z0-9._-' < /etc/machine-id)"
  fi
  [[ -r /sys/class/dmi/id/product_name ]] && product="$(tr -cd 'A-Za-z0-9._ -' < /sys/class/dmi/id/product_name)"
  printf '%s|%s' "$identity" "$product"
}
