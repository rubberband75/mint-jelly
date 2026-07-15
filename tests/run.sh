#!/usr/bin/env bash
# Focused v3 CLI, snapshot, installer-lifecycle, and deployment tests.

set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mint-jelly-tests.XXXXXX")"
TEST_HOME="$TEST_ROOT/home"
TEST_DATA="$TEST_ROOT/data"
TEST_CONFIG="$TEST_ROOT/config"
TEST_STATE="$TEST_ROOT/state"
TEST_CACHE="$TEST_ROOT/cache"
TEST_BIN="$TEST_HOME/.local/bin"
TEST_REMOTE="$TEST_ROOT/remote"

cleanup() { rm -rf -- "$TEST_ROOT"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_file() { [[ -f "$1" ]] || fail "Expected file: $1"; }
assert_not_exists() { [[ ! -e "$1" && ! -L "$1" ]] || fail "Expected path to be absent: $1"; }
assert_contains() {
  local wanted="$1" value; shift
  for value in "$@"; do [[ "$value" == "$wanted" ]] && return 0; done
  fail "Expected '$wanted'; got: $*"
}

mkdir -p -- "$TEST_HOME" "$TEST_CONFIG" "$TEST_STATE" "$TEST_CACHE" "$TEST_REMOTE"

while IFS= read -r script; do bash -n "$script" || fail "Syntax error: $script"; done \
  < <(find "$PROJECT_ROOT" -type f -name '*.sh' -print | sort)
bash -n "$PROJECT_ROOT/mint-jelly"

bash "$PROJECT_ROOT/tests/datagrip-installer.sh" >/dev/null
bash "$PROJECT_ROOT/tests/docker-engine-installer.sh" >/dev/null
bash "$PROJECT_ROOT/tests/google-cloud-cli-installer.sh" >/dev/null
bash "$PROJECT_ROOT/tests/nvm-installer.sh" >/dev/null
bash "$PROJECT_ROOT/tests/vscode-installer.sh" >/dev/null
bash "$PROJECT_ROOT/tests/repositories.sh" >/dev/null

install_env=(
  HOME="$TEST_HOME"
  XDG_DATA_HOME="$TEST_DATA"
  XDG_CONFIG_HOME="$TEST_CONFIG"
  XDG_STATE_HOME="$TEST_STATE"
  XDG_CACHE_HOME="$TEST_CACHE"
  PATH=/usr/bin:/bin
)
env "${install_env[@]}" "$PROJECT_ROOT/install.sh" >/dev/null
env "${install_env[@]}" "$PROJECT_ROOT/install.sh" >/dev/null

LAUNCHER="$TEST_BIN/mint-jelly"
COMPLETION="$TEST_DATA/bash-completion/completions/mint-jelly.bash"
[[ -L "$LAUNCHER" && -x "$LAUNCHER" ]] || fail 'Installer did not create an executable launcher.'
assert_file "$COMPLETION"
[[ "$(HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_DATA" "$LAUNCHER" version)" == 'mint-jelly 0.2.0' ]] \
  || fail 'Installed launcher returned the wrong version.'

export HOME="$TEST_HOME"
export XDG_DATA_HOME="$TEST_DATA"
export XDG_CONFIG_HOME="$TEST_CONFIG"
export XDG_STATE_HOME="$TEST_STATE"
export XDG_CACHE_HOME="$TEST_CACHE"
export PATH="$TEST_BIN:/usr/bin:/bin"

"$LAUNCHER" config init >/dev/null
grep -qx 'version=3' "$TEST_CONFIG/mint-jelly/config.ini" \
  || fail 'config init did not create configuration version 3.'
if grep -q '^backup_plugin=' "$TEST_CONFIG/mint-jelly/config.ini"; then
  fail 'Version 2 configuration still contains backup plugins.'
fi

# Add an isolated local remote and a deterministic recovery selection through
# the inert-data configuration API.
bash -euo pipefail -c '
  SCRIPT_DIR=$1
  source "$SCRIPT_DIR/lib/common.sh"
  source "$SCRIPT_DIR/lib/config.sh"
  config_read
  config_add_remote_name alpha
  REMOTE_TYPE[alpha]=local
  REMOTE_ROOT_PATH[alpha]=$2
  DEFAULT_REMOTE=alpha
  FILE_SPECS=(~/Documents)
  APPLICATIONS=(postman)
  SYSTEM_SETTINGS=(desktop)
  APT_PACKAGES=()
  FLATPAK_APPS=()
  INSTALLERS=(test-app)
  INSTALLER_OPTION_SELECTIONS=()
  config_write
' _ "$TEST_DATA/mint-jelly/current" "$TEST_REMOTE"

mkdir -p -- "$TEST_HOME/Documents"
printf 'original snapshot content\n' > "$TEST_HOME/Documents/important.txt"
mkdir -p -- "$TEST_HOME/.config/Postman"
printf '{"example":true}\n' > "$TEST_HOME/.config/Postman/settings.json"

MINT_JELLY_INSTALLERS_DIR="$PROJECT_ROOT/tests/fakes/installers" \
  "$LAUNCHER" backup >/dev/null
BACKED_HOST="$(hostname)"
CURRENT_FILE="$TEST_REMOTE/$BACKED_HOST/.mint-jelly/current"
assert_file "$CURRENT_FILE"
FIRST_GENERATION="$(<"$CURRENT_FILE")"
FIRST_SNAPSHOT="$TEST_REMOTE/$BACKED_HOST/.mint-jelly/snapshots/$FIRST_GENERATION"
assert_file "$FIRST_SNAPSHOT/snapshot.manifest"
assert_file "$FIRST_SNAPSHOT/files.manifest"
assert_file "$FIRST_SNAPSHOT/software.manifest"
assert_file "$FIRST_SNAPSHOT/system-settings.manifest"
assert_file "$FIRST_SNAPSHOT/data/files/root$TEST_HOME/Documents/important.txt"
assert_file "$FIRST_SNAPSHOT/data/software/root$TEST_HOME/.config/Postman/settings.json"
grep -qx 'application=postman' "$FIRST_SNAPSHOT/software.manifest" \
  || fail 'Software backup omitted the selected Postman configuration profile.'
grep -qx 'profile=desktop|portable' "$FIRST_SNAPSHOT/system-settings.manifest" \
  || fail 'System-settings backup omitted the Desktop profile.'
grep -q '^value=desktop|org.nemo.desktop|computer-icon-visible|' "$FIRST_SNAPSHOT/system-settings.manifest" \
  || fail 'Desktop profile did not capture its explicit Nemo settings.'
grep -qx 'installer=test-app' "$FIRST_SNAPSHOT/software.manifest" \
  || fail 'Unified software manifest omitted the configured installer.'

remote_plan="$(MINT_JELLY_INSTALLERS_DIR="$PROJECT_ROOT/tests/fakes/installers" "$LAUNCHER" software list-remote)"
[[ "$remote_plan" == *'installer: test-app'* ]] \
  || fail 'software list-remote did not read the unified snapshot.'

# A scoped software backup must commit another generation while carrying the
# files domain forward unchanged.
MINT_JELLY_INSTALLERS_DIR="$PROJECT_ROOT/tests/fakes/installers" \
  "$LAUNCHER" software backup >/dev/null
SECOND_GENERATION="$(<"$CURRENT_FILE")"
[[ "$SECOND_GENERATION" != "$FIRST_GENERATION" ]] || fail 'Scoped backup did not create a generation.'
SECOND_SNAPSHOT="$TEST_REMOTE/$BACKED_HOST/.mint-jelly/snapshots/$SECOND_GENERATION"
assert_file "$SECOND_SNAPSHOT/files.manifest"
assert_file "$SECOND_SNAPSHOT/data/files/root$TEST_HOME/Documents/important.txt"

printf 'changed locally\n' > "$TEST_HOME/Documents/important.txt"
"$LAUNCHER" files restore --dry-run --yes --force >/dev/null
grep -qx 'changed locally' "$TEST_HOME/Documents/important.txt" \
  || fail 'Dry-run restore changed local data.'
"$LAUNCHER" files restore --yes --force >/dev/null
grep -qx 'original snapshot content' "$TEST_HOME/Documents/important.txt" \
  || fail 'Files restore did not recover snapshot content.'

# Exercise explicit bundled-installer install/update/uninstall lifecycle.
MARKER="$TEST_ROOT/test-app.installed"
ACTION_LOG="$TEST_ROOT/test-app.actions"
common_action_env=(
  MINT_JELLY_INSTALLERS_DIR="$PROJECT_ROOT/tests/fakes/installers"
  MINT_JELLY_TEST_INSTALL_MARKER="$MARKER"
  MINT_JELLY_TEST_ACTION_LOG="$ACTION_LOG"
)
env "${common_action_env[@]}" "$LAUNCHER" software install test-app >/dev/null
assert_file "$MARKER"
env "${common_action_env[@]}" "$LAUNCHER" software update >/dev/null
grep -qx update "$ACTION_LOG" || fail 'software update did not invoke the installer update action.'
touch -- "$MARKER.config"
env "${common_action_env[@]}" "$LAUNCHER" software uninstall test-app --purge --yes >/dev/null
assert_not_exists "$MARKER"
assert_not_exists "$MARKER.config"
if grep -q '^installer=test-app$' "$TEST_CONFIG/mint-jelly/config.ini"; then
  fail 'Successful software uninstall remained in the recovery plan.'
fi

# Files management is first class and normalizes paths under HOME.
mkdir -p -- "$TEST_HOME/Pictures/Wallpaper"
"$LAUNCHER" files add "$TEST_HOME/Pictures/Wallpaper" >/dev/null
grep -qx 'file=~/Pictures/Wallpaper' "$TEST_CONFIG/mint-jelly/config.ini" \
  || fail 'files add did not normalize and persist the path.'
files_list="$("$LAUNCHER" files list)"
[[ "$files_list" == *'~/Pictures/Wallpaper'* ]] || fail 'files list omitted a configured path.'
"$LAUNCHER" files remove "$TEST_HOME/Pictures/Wallpaper" >/dev/null

# The settings catalog exposes narrow Desktop and Themes profiles and marks
# hardware-sensitive panels for review.
settings_catalog="$($LAUNCHER system-settings --help)"
[[ "$settings_catalog" == Usage:* ]] || fail 'system-settings help is unavailable.'
bash -euo pipefail -c '
  source "$1/lib/common.sh"
  source "$1/lib/system-settings.sh"
  [[ "${SYSTEM_SETTING_CLASS[desktop]}" == portable ]]
  [[ "${SYSTEM_SETTING_SCHEMAS[desktop]}" == org.nemo.desktop ]]
  [[ "${SYSTEM_SETTING_FILES[desktop]-}" == "" ]]
  [[ "${SYSTEM_SETTING_CLASS[display]}" == hardware ]]
' _ "$TEST_DATA/mint-jelly/current" || fail 'System-settings profile boundaries are incorrect.'

# Completion reflects the v3 command hierarchy and safety flags.
source "$COMPLETION"
COMP_WORDS=(mint-jelly f); COMP_CWORD=1; _mint_jelly
assert_contains files "${COMPREPLY[@]}"
COMP_WORDS=(mint-jelly system-settings r); COMP_CWORD=2; _mint_jelly
assert_contains restore "${COMPREPLY[@]}"
COMP_WORDS=(mint-jelly r); COMP_CWORD=1; _mint_jelly
assert_contains repos "${COMPREPLY[@]}"
COMP_WORDS=(mint-jelly software u); COMP_CWORD=2; _mint_jelly
assert_contains update "${COMPREPLY[@]}"
assert_contains uninstall "${COMPREPLY[@]}"
COMP_WORDS=(mint-jelly restore --f); COMP_CWORD=2; _mint_jelly
assert_contains --force "${COMPREPLY[@]}"

# Local and remote lock semantics remain enforced by the shared storage layer.
LOCK_HOST="$TEST_REMOTE/LOCKTEST"
mkdir -p -- "$LOCK_HOST"
bash -euo pipefail -c '
  source "$1/lib/common.sh"; source "$1/lib/remote.sh"
  ACTIVE_REMOTE_TYPE=local; ACTIVE_HOST_BASE=$2
  remote_lock_acquire exclusive
  ! flock -s -n "$ACTIVE_HOST_BASE/.mint-jelly/operation.lock" true
  remote_lock_release
  remote_lock_acquire shared
  flock -s -n "$ACTIVE_HOST_BASE/.mint-jelly/operation.lock" true
  ! flock -x -n "$ACTIVE_HOST_BASE/.mint-jelly/operation.lock" true
  remote_lock_release
' _ "$TEST_DATA/mint-jelly/current" "$LOCK_HOST" || fail 'Remote lock semantics are incorrect.'

"$LAUNCHER" uninstall --yes >/dev/null
assert_not_exists "$TEST_DATA/mint-jelly"
assert_not_exists "$LAUNCHER"
assert_file "$TEST_CONFIG/mint-jelly/config.ini"

env "${install_env[@]}" "$PROJECT_ROOT/install.sh" >/dev/null
"$LAUNCHER" uninstall --purge --yes >/dev/null
assert_not_exists "$TEST_CONFIG/mint-jelly"
assert_not_exists "$TEST_STATE/mint-jelly"
assert_not_exists "$TEST_CACHE/mint-jelly"

printf 'All Mint Jelly tests passed.\n'
