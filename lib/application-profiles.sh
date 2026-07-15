#!/usr/bin/env bash

# Trusted application-data catalog. Paths are configuration/state only; caches
# and installed application payloads are deliberately excluded.

APPLICATION_PROFILE_IDS=(
  datagrip discord firefox google-cloud-cli heroic makemkv minecraft-launcher nvm
  postman slack
)
declare -Ag APPLICATION_PROFILE_NAME=(
  [datagrip]='DataGrip'
  [discord]='Discord'
  [firefox]='Firefox'
  [google-cloud-cli]='Google Cloud CLI'
  [heroic]='Heroic Games Launcher'
  [makemkv]='MakeMKV'
  [minecraft-launcher]='Minecraft Launcher'
  [nvm]='NVM / npm user configuration'
  [postman]='Postman'
  [slack]='Slack Desktop'
)
declare -Ag APPLICATION_PROFILE_PATHS=(
  [datagrip]='~/.config/JetBrains/DataGrip* ~/.local/share/JetBrains/DataGrip*'
  [discord]='~/.config/discord ~/.var/app/com.discordapp.Discord/config/discord'
  [firefox]='~/.mozilla/firefox ~/.var/app/org.mozilla.firefox/.mozilla/firefox'
  [google-cloud-cli]='~/.config/gcloud'
  [heroic]='~/.config/heroic ~/.var/app/com.heroicgameslauncher.hgl/config/heroic'
  [makemkv]='~/.MakeMKV'
  [minecraft-launcher]='~/.minecraft ~/.local/share/minecraft-launcher'
  [nvm]='~/.npmrc ~/.config/configstore'
  [postman]='~/.config/Postman ~/.var/app/com.getpostman.Postman/config/Postman'
  [slack]='~/.config/Slack ~/.var/app/com.slack.Slack/config/Slack'
)
declare -Ag APPLICATION_PROFILE_INSTALLER=(
  [datagrip]='datagrip'
  [discord]='discord'
  [google-cloud-cli]='google-cloud-cli'
  [heroic]='heroic'
  [makemkv]='makemkv'
  [minecraft-launcher]='minecraft-launcher'
  [nvm]='nvm'
  [postman]='postman'
  [slack]='slack'
)
declare -Ag APPLICATION_PROFILE_APT=(
  [firefox]='firefox'
)
declare -Ag APPLICATION_PROFILE_PROCESS=(
  [firefox]='firefox'
)

application_profile_exists() {
  [[ -n "${APPLICATION_PROFILE_NAME[$1]-}" ]]
}

require_configured_application_profiles() {
  local profile
  for profile in "${APPLICATIONS[@]}"; do
    application_profile_exists "$profile" \
      || die "Unknown application profile '$profile'."
  done
}

application_profile_is_configured_software() {
  local profile="$1" expected value spec
  expected="${APPLICATION_PROFILE_INSTALLER[$profile]-}"
  if [[ -n "$expected" ]]; then
    for value in "${INSTALLERS[@]}"; do
      [[ "$value" == "$expected" ]] && return 0
    done
  fi
  expected="${APPLICATION_PROFILE_APT[$profile]-}"
  if [[ -n "$expected" ]]; then
    for value in "${APT_PACKAGES[@]}"; do
      [[ "$value" == "$expected" ]] && return 0
    done
  fi
  for spec in "${FLATPAK_APPS[@]}"; do
    IFS='|' read -r _ _ value _ <<< "$spec"
    case "$profile:$value" in
      discord:com.discordapp.Discord|firefox:org.mozilla.firefox|heroic:com.heroicgameslauncher.hgl|postman:com.getpostman.Postman|slack:com.slack.Slack)
        return 0
        ;;
    esac
  done
  return 1
}

application_profile_selected() {
  local expected="$1" value
  for value in "${APPLICATIONS[@]}"; do
    [[ "$value" == "$expected" ]] && return 0
  done
  return 1
}

application_auto_select_profiles() {
  local profile
  for profile in "${APPLICATION_PROFILE_IDS[@]}"; do
    application_profile_is_configured_software "$profile" || continue
    application_profile_selected "$profile" || APPLICATIONS+=("$profile")
  done
}

application_expand_profile_paths() {
  local profile="$1" pattern expanded
  local -a matches=()
  APPLICATION_EXPANDED_PATHS=()
  application_profile_exists "$profile" || die "Unknown application profile '$profile'."
  for pattern in ${APPLICATION_PROFILE_PATHS[$profile]}; do
    if [[ "$pattern" == '~/'* ]]; then
      pattern="$HOME/${pattern:2}"
    fi
    validate_absolute_path "$pattern" || die "Application profile '$profile' contains an unsafe path."
    mapfile -t matches < <(compgen -G "$pattern" || true)
    for expanded in "${matches[@]}"; do
      [[ -e "$expanded" || -L "$expanded" ]] || continue
      validate_absolute_path "$expanded" || die "Application profile '$profile' expanded to an unsafe path."
      APPLICATION_EXPANDED_PATHS+=("$expanded")
    done
  done
}

application_profile_preflight_backup() {
  local profile="$1" process="${APPLICATION_PROFILE_PROCESS[$1]-}"
  [[ -n "$process" ]] || return 0
  command -v pgrep >/dev/null 2>&1 || die "pgrep is required to safely back up ${APPLICATION_PROFILE_NAME[$profile]}."
  if pgrep -u "$UID" -x "$process" >/dev/null 2>&1; then
    die "Close ${APPLICATION_PROFILE_NAME[$profile]} before backing it up; its live profile cannot be snapshotted consistently."
  fi
}

application_profile_preflight_restore() {
  local profile="$1" process="${APPLICATION_PROFILE_PROCESS[$1]-}"
  [[ -n "$process" ]] || return 0
  command -v pgrep >/dev/null 2>&1 || die "pgrep is required to safely restore ${APPLICATION_PROFILE_NAME[$profile]}."
  if pgrep -u "$UID" -x "$process" >/dev/null 2>&1; then
    die "Close ${APPLICATION_PROFILE_NAME[$profile]} before restoring its configuration."
  fi
}
