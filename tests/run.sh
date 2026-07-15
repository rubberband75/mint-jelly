#!/usr/bin/env bash
# Focused CLI, completion, installation, and uninstallation tests.

set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mint-jelly-tests.XXXXXX")"
TEST_HOME="$TEST_ROOT/home"
TEST_DATA="$TEST_ROOT/data"
TEST_CONFIG="$TEST_ROOT/config"
TEST_STATE="$TEST_ROOT/state"
TEST_BIN="$TEST_HOME/.local/bin"

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "Expected file: $1"
}

assert_not_exists() {
  [[ ! -e "$1" && ! -L "$1" ]] || fail "Expected path to be absent: $1"
}

assert_contains() {
  local expected="$1"
  shift
  local value

  for value in "$@"; do
    [[ "$value" == "$expected" ]] && return 0
  done
  fail "Expected completion '$expected'; got: $*"
}

assert_recovery_rejected() {
  local label="$1"
  local manifest="$2"

  if bash -euo pipefail -c '
    source "$1/lib/common.sh"
    source "$1/lib/recovery.sh"
    recovery_read "$2"
  ' _ "$TEST_DATA/mint-jelly/current" "$manifest" >/dev/null 2>&1; then
    fail "Recovery parser accepted $label."
  fi
}

run_installer() {
  env \
    HOME="$TEST_HOME" \
    XDG_DATA_HOME="$TEST_DATA" \
    XDG_CONFIG_HOME="$TEST_CONFIG" \
    XDG_STATE_HOME="$TEST_STATE" \
    PATH='/usr/bin:/bin' \
    "$PROJECT_ROOT/install.sh" >/dev/null
}

mkdir -p -- "$TEST_HOME" "$TEST_CONFIG/mint-jelly" "$TEST_STATE/mint-jelly"
install -m 0600 -- \
  "$PROJECT_ROOT/tests/fixtures/backup.conf" \
  "$TEST_CONFIG/mint-jelly/backup.conf"

help_output="$(HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_DATA" "$PROJECT_ROOT/install.sh" --help)"
[[ "$help_output" == Usage:* ]] || fail 'Installer help did not print usage.'
assert_not_exists "$TEST_DATA/mint-jelly"

if env \
  HOME="$TEST_HOME" \
  XDG_DATA_HOME="$TEST_DATA" \
  MINT_JELLY_INSTALL_DIR="$TEST_HOME/scratch/.." \
  PATH='/usr/bin:/bin' \
  "$PROJECT_ROOT/install.sh" >/dev/null 2>&1; then
  fail 'Installer accepted a path that normalized to the home directory.'
fi
assert_not_exists "$TEST_HOME/.mint-jelly-install"

if invalid_source_error="$(env \
  HOME="$TEST_HOME" \
  XDG_DATA_HOME="$TEST_DATA" \
  MINT_JELLY_SOURCE_DIR="$TEST_ROOT/missing-source" \
  PATH='/usr/bin:/bin' \
  "$PROJECT_ROOT/install.sh" 2>&1)"; then
  fail 'Installer silently fell back from an explicit missing source directory.'
fi
[[ "$invalid_source_error" == *'Explicit Mint Jelly source directory does not exist'* ]] \
  || fail "Explicit missing source failed unclearly: $invalid_source_error"

# Installed command modes are properties of their runtime roles, not of the
# checkout or release archive. This is the regression case for software.sh
# arriving without an executable bit and then failing through the launcher.
MODE_SOURCE="$TEST_ROOT/mode-source"
MODE_HOME="$TEST_ROOT/mode-home"
MODE_DATA="$TEST_ROOT/mode-data"
cp -a -- "$PROJECT_ROOT" "$MODE_SOURCE"
while IFS= read -r runtime_path || [[ -n "$runtime_path" ]]; do
  [[ -z "$runtime_path" || "$runtime_path" == \#* ]] && continue
  chmod 0644 -- "$MODE_SOURCE/$runtime_path"
done < "$MODE_SOURCE/install-manifest.txt"
mkdir -p -- "$MODE_HOME"
env \
  HOME="$MODE_HOME" \
  XDG_DATA_HOME="$MODE_DATA" \
  MINT_JELLY_SOURCE_DIR="$MODE_SOURCE" \
  PATH='/usr/bin:/bin' \
  bash "$MODE_SOURCE/install.sh" >/dev/null
while IFS= read -r runtime_path || [[ -n "$runtime_path" ]]; do
  [[ -z "$runtime_path" || "$runtime_path" == \#* ]] && continue
  case "$runtime_path" in
    mint-jelly|backup.sh|restore.sh|software.sh|configure.sh|configure-backup-plugins.sh|configure-installers.sh|configure-apt.sh|uninstall.sh|installers/*/run.sh)
      [[ -x "$MODE_DATA/mint-jelly/current/$runtime_path" ]] \
        || fail "Installer did not make runtime command executable: $runtime_path"
      ;;
    *)
      [[ ! -x "$MODE_DATA/mint-jelly/current/$runtime_path" ]] \
        || fail "Installer made runtime data executable: $runtime_path"
      ;;
  esac
done < "$MODE_SOURCE/install-manifest.txt"
rm -rf -- "$MODE_SOURCE" "$MODE_HOME" "$MODE_DATA"

# Exercise the piped/downloaded bootstrap without network access. The fake curl
# refuses requests unless both the initial URL and every redirect are pinned to
# HTTPS, then serves a locally built release archive and controlled checksum.
RELEASE_TEST_ROOT="$TEST_ROOT/release-bootstrap"
RELEASE_BUILD="$RELEASE_TEST_ROOT/build"
RELEASE_ARCHIVE="$RELEASE_TEST_ROOT/mint-jelly-v0.0.2.tar.gz"
RELEASE_BOOTSTRAP="$RELEASE_TEST_ROOT/bootstrap/install.sh"
mkdir -p -- "$RELEASE_BUILD/mint-jelly-v0.0.2" \
  "$(dirname -- "$RELEASE_BOOTSTRAP")"
cp -a -- "$PROJECT_ROOT/." "$RELEASE_BUILD/mint-jelly-v0.0.2/"
tar -czf "$RELEASE_ARCHIVE" -C "$RELEASE_BUILD" mint-jelly-v0.0.2
install -m 0755 -- "$PROJECT_ROOT/install.sh" "$RELEASE_BOOTSTRAP"

run_release_bootstrap() {
  local case_name="$1"
  local checksum_mode="${2:-valid}"
  local case_root="$RELEASE_TEST_ROOT/$case_name"

  mkdir -p -- "$case_root/home"
  env \
    HOME="$case_root/home" \
    XDG_DATA_HOME="$case_root/data" \
    MINT_JELLY_BIN_DIR="$case_root/bin" \
    MINT_JELLY_VERSION='0.0.2' \
    MINT_JELLY_REPOSITORY='test-owner/mint-jelly' \
    MINT_JELLY_TEST_RELEASE_ARCHIVE="$RELEASE_ARCHIVE" \
    MINT_JELLY_TEST_CURL_LOG="$case_root/curl.log" \
    MINT_JELLY_TEST_CHECKSUM_MODE="$checksum_mode" \
    PATH="$PROJECT_ROOT/tests/fakes/release:/usr/bin:/bin" \
    bash "$RELEASE_BOOTSTRAP"
}

run_release_bootstrap valid >/dev/null
RELEASE_LAUNCHER="$RELEASE_TEST_ROOT/valid/bin/mint-jelly"
[[ -x "$RELEASE_LAUNCHER" ]] \
  || fail 'Offline release bootstrap did not install an executable launcher target.'
[[ "$($RELEASE_LAUNCHER version)" == 'mint-jelly 0.0.2' ]] \
  || fail 'Offline release bootstrap installed the wrong version.'
grep -qx 'https://github.com/test-owner/mint-jelly/releases/download/v0.0.2/mint-jelly-v0.0.2.tar.gz' \
  "$RELEASE_TEST_ROOT/valid/curl.log" \
  || fail 'Release bootstrap requested an unexpected archive URL.'
grep -qx 'https://github.com/test-owner/mint-jelly/releases/download/v0.0.2/mint-jelly-v0.0.2.tar.gz.sha256' \
  "$RELEASE_TEST_ROOT/valid/curl.log" \
  || fail 'Release bootstrap requested an unexpected checksum URL.'

if checksum_error="$(run_release_bootstrap wrong-filename wrong-filename 2>&1)"; then
  fail 'Release bootstrap accepted a checksum for the wrong filename.'
fi
[[ "$checksum_error" == *'Release checksum file has an unexpected format or filename.'* ]] \
  || fail "Wrong checksum filename failed unclearly: $checksum_error"

if checksum_error="$(run_release_bootstrap extra-entry extra-entry 2>&1)"; then
  fail 'Release bootstrap accepted multiple checksum entries.'
fi
[[ "$checksum_error" == *'Release checksum file must contain exactly one entry.'* ]] \
  || fail "Multiple checksum entries failed unclearly: $checksum_error"

if checksum_error="$(run_release_bootstrap bad-hash bad-hash 2>&1)"; then
  fail 'Release bootstrap accepted a mismatched archive checksum.'
fi
[[ "$checksum_error" == *'Release checksum verification failed.'* ]] \
  || fail "Mismatched release checksum failed unclearly: $checksum_error"

INVALID_RELEASE_ROOT="$RELEASE_TEST_ROOT/invalid-input"
mkdir -p -- "$INVALID_RELEASE_ROOT/home"
if release_error="$(env \
  HOME="$INVALID_RELEASE_ROOT/home" \
  XDG_DATA_HOME="$INVALID_RELEASE_ROOT/data" \
  MINT_JELLY_VERSION='not-a-version' \
  MINT_JELLY_REPOSITORY='test-owner/mint-jelly' \
  MINT_JELLY_TEST_RELEASE_ARCHIVE="$RELEASE_ARCHIVE" \
  MINT_JELLY_TEST_CURL_LOG="$INVALID_RELEASE_ROOT/version-curl.log" \
  PATH="$PROJECT_ROOT/tests/fakes/release:/usr/bin:/bin" \
  bash "$RELEASE_BOOTSTRAP" 2>&1)"; then
  fail 'Release bootstrap accepted an invalid requested version.'
fi
[[ "$release_error" == *'Invalid release version: not-a-version'* ]] \
  || fail "Invalid release version failed unclearly: $release_error"
[[ ! -e "$INVALID_RELEASE_ROOT/version-curl.log" ]] \
  || fail 'Invalid release version reached curl.'

if release_error="$(env \
  HOME="$INVALID_RELEASE_ROOT/home" \
  XDG_DATA_HOME="$INVALID_RELEASE_ROOT/data" \
  MINT_JELLY_VERSION='0.0.2' \
  MINT_JELLY_REPOSITORY='test-owner/mint-jelly/extra' \
  MINT_JELLY_TEST_RELEASE_ARCHIVE="$RELEASE_ARCHIVE" \
  MINT_JELLY_TEST_CURL_LOG="$INVALID_RELEASE_ROOT/repository-curl.log" \
  PATH="$PROJECT_ROOT/tests/fakes/release:/usr/bin:/bin" \
  bash "$RELEASE_BOOTSTRAP" 2>&1)"; then
  fail 'Release bootstrap accepted an invalid GitHub repository.'
fi
[[ "$release_error" == *'Invalid GitHub repository: test-owner/mint-jelly/extra'* ]] \
  || fail "Invalid release repository failed unclearly: $release_error"
[[ ! -e "$INVALID_RELEASE_ROOT/repository-curl.log" ]] \
  || fail 'Invalid release repository reached curl.'

run_installer
run_installer

LAUNCHER="$TEST_BIN/mint-jelly"
COMPLETION="$TEST_DATA/bash-completion/completions/mint-jelly.bash"
installed_version_file="$(find "$TEST_DATA/mint-jelly/versions" -mindepth 2 -maxdepth 2 -name VERSION -print -quit)"
[[ -n "$installed_version_file" ]] || fail 'Expected an installed version deployment.'
assert_file "$installed_version_file"
assert_file "$COMPLETION"
[[ -L "$LAUNCHER" ]] || fail "Expected launcher symlink: $LAUNCHER"
[[ ! -e "$TEST_HOME/.bashrc" ]] || fail 'Installer must not create or edit .bashrc.'

version_output="$(
  HOME="$TEST_HOME" \
  XDG_DATA_HOME="$TEST_DATA" \
  XDG_CONFIG_HOME="$TEST_CONFIG" \
  XDG_STATE_HOME="$TEST_STATE" \
  "$LAUNCHER" version
)"
[[ "$version_output" == 'mint-jelly 0.0.2' ]] \
  || fail "Unexpected version output: $version_output"
[[ -x "$TEST_DATA/mint-jelly/current/software.sh" ]] \
  || fail 'Installed software command is not executable.'

# Recovery manifests are inert, bounded input. Exercise rejection separately
# from the CLI so failures cannot be mistaken for remote-connection errors.
MANIFEST_TEST_DIR="$TEST_ROOT/manifest-tests"
mkdir -p -- "$MANIFEST_TEST_DIR"
cp -- "$PROJECT_ROOT/tests/fixtures/recovery.manifest" "$MANIFEST_TEST_DIR/unknown"
printf 'unknown_key=value\n' >> "$MANIFEST_TEST_DIR/unknown"
assert_recovery_rejected 'an unknown key' "$MANIFEST_TEST_DIR/unknown"

cp -- "$PROJECT_ROOT/tests/fixtures/recovery.manifest" "$MANIFEST_TEST_DIR/duplicate"
printf 'source=/home/tester/.ssh\n' >> "$MANIFEST_TEST_DIR/duplicate"
assert_recovery_rejected 'a duplicate source' "$MANIFEST_TEST_DIR/duplicate"

head -n 6 "$PROJECT_ROOT/tests/fixtures/recovery.manifest" > "$MANIFEST_TEST_DIR/long-line"
long_component="$(head -c 4096 /dev/zero | tr '\0' a)"
printf 'source=/%s\n' "$long_component" >> "$MANIFEST_TEST_DIR/long-line"
assert_recovery_rejected 'an overlong line' "$MANIFEST_TEST_DIR/long-line"

cp -- "$PROJECT_ROOT/tests/fixtures/recovery.manifest" "$MANIFEST_TEST_DIR/nul"
printf 'installer=bad\0value\n' >> "$MANIFEST_TEST_DIR/nul"
assert_recovery_rejected 'a NUL byte' "$MANIFEST_TEST_DIR/nul"

truncate -s 1048577 "$MANIFEST_TEST_DIR/oversized"
assert_recovery_rejected 'an oversized manifest' "$MANIFEST_TEST_DIR/oversized"

head -n 6 "$PROJECT_ROOT/tests/fixtures/recovery.manifest" > "$MANIFEST_TEST_DIR/too-many-sources"
for ((index = 0; index <= 256; index += 1)); do
  printf 'source=/bounded-source-%d\n' "$index" \
    >> "$MANIFEST_TEST_DIR/too-many-sources"
done
assert_recovery_rejected 'too many sources' "$MANIFEST_TEST_DIR/too-many-sources"

export HOME="$TEST_HOME"
export XDG_DATA_HOME="$TEST_DATA"
export XDG_CONFIG_HOME="$TEST_CONFIG"
export XDG_STATE_HOME="$TEST_STATE"
export PATH="$TEST_BIN:/usr/bin:/bin"

"$LAUNCHER" config apt add git >/dev/null
grep -qx 'apt_package=git' "$TEST_CONFIG/mint-jelly/backup.conf" \
  || fail 'APT add did not update the configuration.'
"$LAUNCHER" config apt remove git >/dev/null
if grep -q '^apt_package=git$' "$TEST_CONFIG/mint-jelly/backup.conf"; then
  fail 'APT remove did not update the configuration.'
fi

# shellcheck source=/dev/null
source "$COMPLETION"

COMP_WORDS=(mint-jelly con)
COMP_CWORD=1
_mint_jelly
assert_contains config "${COMPREPLY[@]}"

COMP_WORDS=(mint-jelly sof)
COMP_CWORD=1
_mint_jelly
assert_contains software "${COMPREPLY[@]}"

COMP_WORDS=(mint-jelly config remote s)
COMP_CWORD=3
_mint_jelly
assert_contains set-default "${COMPREPLY[@]}"

COMP_WORDS=(mint-jelly backup --remote a)
COMP_CWORD=3
_mint_jelly
assert_contains alpha "${COMPREPLY[@]}"
assert_contains archive-2 "${COMPREPLY[@]}"

COMP_WORDS=(mint-jelly restore --a)
COMP_CWORD=2
_mint_jelly
assert_contains --allow-platform-mismatch "${COMPREPLY[@]}"

COMP_WORDS=(mint-jelly software install --allow-w)
COMP_CWORD=3
_mint_jelly
assert_contains --allow-weak-verification "${COMPREPLY[@]}"

COMP_WORDS=(mint-jelly config apt s)
COMP_CWORD=3
_mint_jelly
assert_contains select "${COMPREPLY[@]}"

# Point the isolated configuration at an isolated local mirror.
TEST_REMOTE="$TEST_ROOT/remote"
export TEST_REMOTE

# A shared remote lock permits other readers but excludes a writer; an
# exclusive lock excludes both. Releasing the process drops the advisory lock
# without deleting or managing stale lock directories.
mkdir -p -- "$TEST_REMOTE/LOCKTEST"
(
  # shellcheck source=/dev/null
  source "$TEST_DATA/mint-jelly/current/lib/common.sh"
  # shellcheck source=/dev/null
  source "$TEST_DATA/mint-jelly/current/lib/remote.sh"
  ACTIVE_REMOTE_TYPE='local'
  ACTIVE_HOST_BASE="$TEST_REMOTE/LOCKTEST"
  remote_lock_acquire exclusive
  if flock -s -n "$ACTIVE_HOST_BASE/.mint-jelly/operation.lock" true; then
    exit 1
  fi
  remote_lock_release
  remote_lock_acquire shared
  flock -s -n "$ACTIVE_HOST_BASE/.mint-jelly/operation.lock" true
  if flock -x -n "$ACTIVE_HOST_BASE/.mint-jelly/operation.lock" true; then
    exit 1
  fi
  remote_lock_release
) || fail 'Remote shared/exclusive lock behavior is incorrect.'
[[ "$(stat -c '%a' "$TEST_REMOTE/LOCKTEST/.mint-jelly/operation.lock")" == '600' ]] \
  || fail 'Remote lock file does not have mode 0600.'

# Write-mode setup must never follow the hostname component through a
# symbolic link. The configured root itself may intentionally resolve through
# a symlink, but the per-host mirror boundary must be a real directory.
mkdir -p -- "$TEST_REMOTE/HOST-LINK-TARGET"
ln -s -- "$TEST_REMOTE/HOST-LINK-TARGET" "$TEST_REMOTE/HOST-LINK"
if host_link_error="$(
  (
    # shellcheck source=/dev/null
    source "$TEST_DATA/mint-jelly/current/lib/common.sh"
    # shellcheck source=/dev/null
    source "$TEST_DATA/mint-jelly/current/lib/config.sh"
    # shellcheck source=/dev/null
    source "$TEST_DATA/mint-jelly/current/lib/remote.sh"
    config_add_remote_name safety
    REMOTE_TYPE[safety]='local'
    REMOTE_ROOT_PATH[safety]="$TEST_REMOTE"
    remote_open safety HOST-LINK write
  ) 2>&1
)"; then
  fail 'Local write-mode remote setup accepted a symlinked host directory.'
fi
[[ "$host_link_error" == *'unsafe local backup directory'* ]] \
  || fail "Local host-directory symlink failed unclearly: $host_link_error"
if ssh_host_link_error="$(
  (
    # shellcheck source=/dev/null
    source "$TEST_DATA/mint-jelly/current/lib/common.sh"
    # shellcheck source=/dev/null
    source "$TEST_DATA/mint-jelly/current/lib/config.sh"
    # shellcheck source=/dev/null
    source "$TEST_DATA/mint-jelly/current/lib/remote.sh"
    ssh() {
      local command="${!#}"
      sh -c "$command"
    }
    config_add_remote_name safety
    REMOTE_TYPE[safety]='ssh'
    REMOTE_HOST[safety]='fake-target'
    REMOTE_USERNAME[safety]='tester'
    REMOTE_PORT[safety]='22'
    REMOTE_ROOT_PATH[safety]="$TEST_REMOTE"
    remote_open safety HOST-LINK write
  ) 2>&1
)"; then
  fail 'SSH write-mode remote setup accepted a symlinked host directory.'
fi
[[ "$ssh_host_link_error" == *'Remote backup directory is not writable'* ]] \
  || fail "SSH host-directory symlink failed unclearly: $ssh_host_link_error"

# A final source leaf may be a symlink because rsync copies the link itself.
# A directory destination, or any of its ancestors below the host boundary,
# may not be a symlink because mkdir/rsync would follow it.
mkdir -p -- \
  "$TEST_REMOTE/PATH-SAFETY/safe" \
  "$TEST_REMOTE/PATH-SAFETY-OUTSIDE"
ln -s -- "$TEST_REMOTE/PATH-SAFETY-OUTSIDE" \
  "$TEST_REMOTE/PATH-SAFETY/safe/final-link"
(
  # shellcheck source=/dev/null
  source "$TEST_DATA/mint-jelly/current/lib/common.sh"
  # shellcheck source=/dev/null
  source "$TEST_DATA/mint-jelly/current/lib/remote.sh"
  ACTIVE_REMOTE_TYPE='local'
  ACTIVE_HOST_BASE="$TEST_REMOTE/PATH-SAFETY"
  remote_lock_acquire exclusive
  remote_assert_mirror_path \
    "$ACTIVE_HOST_BASE/safe/final-link" leaf
  remote_lock_release
) || fail 'A safe final source symlink was rejected.'
if path_link_error="$(
  (
    # shellcheck source=/dev/null
    source "$TEST_DATA/mint-jelly/current/lib/common.sh"
    # shellcheck source=/dev/null
    source "$TEST_DATA/mint-jelly/current/lib/remote.sh"
    ACTIVE_REMOTE_TYPE='local'
    ACTIVE_HOST_BASE="$TEST_REMOTE/PATH-SAFETY"
    remote_lock_acquire exclusive
    remote_ensure_directory "$ACTIVE_HOST_BASE/safe/final-link/child"
  ) 2>&1
)"; then
  fail 'Local mirror directory creation followed a symbolic-link component.'
fi
[[ "$path_link_error" == *'Unsafe symbolic-link mirror component'* ]] \
  || fail "Local mirror symlink failed unclearly: $path_link_error"
assert_not_exists "$TEST_REMOTE/PATH-SAFETY-OUTSIDE/child"

# Exercise the SSH-only mechanics without a network server: the fake ssh
# function executes the fully quoted remote command in a child shell. This
# covers the long-lived coprocess lock channel and exact-byte stdin manifest
# commit rather than the local-filesystem branch above.
mkdir -p -- "$TEST_REMOTE/SSH-TRANSPORT" "$TEST_ROOT/ssh-transport"
(
  # shellcheck source=/dev/null
  source "$TEST_DATA/mint-jelly/current/lib/common.sh"
  # shellcheck source=/dev/null
  source "$TEST_DATA/mint-jelly/current/lib/recovery.sh"
  # shellcheck source=/dev/null
  source "$TEST_DATA/mint-jelly/current/lib/remote.sh"
  ssh() {
    local target="$1"
    local command="$2"
    [[ "$target" == 'fake-target' ]]
    sh -c "$command"
  }
  ACTIVE_REMOTE_TYPE='ssh'
  ACTIVE_HOST_BASE="$TEST_REMOTE/SSH-TRANSPORT"
  SSH_TARGET='fake-target'
  SSH_OPTIONS=()
  remote_lock_acquire exclusive
  remote_write_recovery_manifest "$PROJECT_ROOT/tests/fixtures/recovery.manifest"
  remote_read_recovery_manifest > "$TEST_ROOT/ssh-transport/read-back"
  cmp -s "$PROJECT_ROOT/tests/fixtures/recovery.manifest" \
    "$TEST_ROOT/ssh-transport/read-back"
  remote_lock_release
) || fail 'Simulated SSH lock or streamed manifest commit failed.'
[[ "$(stat -c '%a' "$TEST_REMOTE/SSH-TRANSPORT/.mint-jelly/recovery.manifest")" == '600' ]] \
  || fail 'SSH-streamed recovery manifest does not have mode 0600.'
if find "$TEST_REMOTE/SSH-TRANSPORT/.mint-jelly" -maxdepth 1 \
  -name '.recovery.manifest.tmp.*' -print -quit | grep -q .; then
  fail 'SSH-streamed recovery manifest left a staging file behind.'
fi

# The SSH lock guard must notice that its long-lived holder has exited rather
# than trusting the last recorded lock mode. Send an invalid private protocol
# message to make the real simulated holder exit deterministically.
if lost_lock_error="$(
  (
    # shellcheck source=/dev/null
    source "$TEST_DATA/mint-jelly/current/lib/common.sh"
    # shellcheck source=/dev/null
    source "$TEST_DATA/mint-jelly/current/lib/remote.sh"
    ssh() {
      local target="$1"
      local command="$2"
      [[ "$target" == 'fake-target' ]]
      sh -c "$command"
    }
    ACTIVE_REMOTE_TYPE='ssh'
    ACTIVE_HOST_BASE="$TEST_REMOTE/SSH-TRANSPORT"
    SSH_TARGET='fake-target'
    SSH_OPTIONS=()
    remote_lock_acquire exclusive
    printf 'STOP\n' >&"$REMOTE_LOCK_INPUT_FD"
    wait "$REMOTE_LOCK_PID" 2>/dev/null || true
    remote_require_lock exclusive
  ) 2>&1
)"; then
  fail 'A protected SSH operation accepted a dead remote lock holder.'
fi
[[ "$lost_lock_error" == *'SSH remote lock was lost; refusing to continue'* ]] \
  || fail "SSH lock loss failed unclearly: $lost_lock_error"

# Exercise the same path-component rejection through the SSH implementation.
mkdir -p -- \
  "$TEST_REMOTE/SSH-PATH-SAFETY/safe" \
  "$TEST_REMOTE/SSH-PATH-SAFETY-OUTSIDE"
ln -s -- "$TEST_REMOTE/SSH-PATH-SAFETY-OUTSIDE" \
  "$TEST_REMOTE/SSH-PATH-SAFETY/safe/redirect"
if ssh_path_error="$(
  (
    # shellcheck source=/dev/null
    source "$TEST_DATA/mint-jelly/current/lib/common.sh"
    # shellcheck source=/dev/null
    source "$TEST_DATA/mint-jelly/current/lib/remote.sh"
    ssh() {
      local target="$1"
      local command="$2"
      [[ "$target" == 'fake-target' ]]
      sh -c "$command"
    }
    ACTIVE_REMOTE_TYPE='ssh'
    ACTIVE_HOST_BASE="$TEST_REMOTE/SSH-PATH-SAFETY"
    SSH_TARGET='fake-target'
    SSH_OPTIONS=()
    trap remote_close EXIT
    remote_lock_acquire exclusive
    remote_ensure_directory "$ACTIVE_HOST_BASE/safe/redirect/child"
  ) 2>&1
)"; then
  fail 'SSH mirror directory creation followed a symbolic-link component.'
fi
[[ "$ssh_path_error" == *'Unsafe symbolic-link mirror component'* ]] \
  || fail "SSH mirror symlink failed unclearly: $ssh_path_error"
assert_not_exists "$TEST_REMOTE/SSH-PATH-SAFETY-OUTSIDE/child"

(
  SCRIPT_DIR="$TEST_DATA/mint-jelly/current"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/common.sh"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/config.sh"
  config_read
  REMOTE_ROOT_PATH[alpha]="$TEST_REMOTE"
  APT_PACKAGES=(git)
  INSTALLERS=(postman)
  config_write
)
"$LAUNCHER" config remote test alpha >/dev/null
mkdir -p -- "$TEST_HOME/.ssh"
install -m 0600 -- "$PROJECT_ROOT/tests/fixtures/backup.conf" "$TEST_HOME/.ssh/test-key"

"$LAUNCHER" backup --remote alpha >/dev/null
BACKED_HOST="$(hostname)"
BACKED_MANIFEST="$TEST_REMOTE/$BACKED_HOST/.mint-jelly/recovery.manifest"
assert_file "$BACKED_MANIFEST"
grep -qx 'apt_package=git' "$BACKED_MANIFEST" \
  || fail 'Backup recovery manifest did not snapshot the configured APT package.'
grep -qx 'installer=postman' "$BACKED_MANIFEST" \
  || fail 'Backup recovery manifest did not snapshot the configured installer.'
"$LAUNCHER" restore --remote alpha --source-host "$BACKED_HOST" --dry-run >/dev/null

cp -- "$BACKED_MANIFEST" "$BACKED_MANIFEST.platform-match"
sed -i 's/^os_version=.*/os_version=0.0/' "$BACKED_MANIFEST"
if "$LAUNCHER" restore --remote alpha --source-host "$BACKED_HOST" \
  --dry-run >/dev/null 2>&1; then
  fail 'Restore accepted a platform mismatch without an explicit override.'
fi
"$LAUNCHER" restore --remote alpha --source-host "$BACKED_HOST" \
  --dry-run --allow-platform-mismatch >/dev/null 2>&1
mv -f -- "$BACKED_MANIFEST.platform-match" "$BACKED_MANIFEST"

# A non-directory source directly beneath / must retain its exact absolute
# path instead of being copied into a duplicate basename directory. /bin is a
# top-level symlink on supported Linux Mint releases, so it is a safe fixture.
(
  # shellcheck source=/dev/null
  SCRIPT_DIR="$TEST_DATA/mint-jelly/current"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/common.sh"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/config.sh"
  config_read
  BACKUP_SOURCE_SPECS=(/bin)
  BACKUP_PLUGINS=()
  config_write
)
"$LAUNCHER" backup --remote alpha >/dev/null
[[ -L "$TEST_REMOTE/$BACKED_HOST/bin" ]] \
  || fail 'A top-level symbolic-link source did not retain its absolute path.'
assert_not_exists "$TEST_REMOTE/$BACKED_HOST/bin/bin"

mkdir -p -- "$TEST_REMOTE/TESTHOST/.mint-jelly"
install -m 0600 -- \
  "$PROJECT_ROOT/tests/fixtures/recovery.manifest" \
  "$TEST_REMOTE/TESTHOST/.mint-jelly/recovery.manifest"

exec {held_remote_lock}>> "$TEST_REMOTE/TESTHOST/.mint-jelly/operation.lock"
flock -x "$held_remote_lock"
if lock_error="$(
  MINT_JELLY_REMOTE_LOCK_TIMEOUT=1 \
  MINT_JELLY_OS_RELEASE_FILE="$PROJECT_ROOT/tests/fixtures/os-release" \
    "$LAUNCHER" software show --remote alpha --source-host TESTHOST 2>&1
)"; then
  fail 'Software read ignored an exclusive remote lock.'
fi
flock -u "$held_remote_lock"
exec {held_remote_lock}>&-
[[ "$lock_error" == *'Timed out waiting for the shared remote lock after 1 seconds.'* ]] \
  || fail "Remote lock contention did not fail clearly: $lock_error"

software_show="$(
  MINT_JELLY_OS_RELEASE_FILE="$PROJECT_ROOT/tests/fixtures/os-release" \
    "$LAUNCHER" software show --remote alpha --source-host TESTHOST
)"
[[ "$software_show" == *'mint-jelly-test-package'* ]] \
  || fail 'Software show did not read the saved APT package.'
[[ "$software_show" == *'postman'* ]] \
  || fail 'Software show did not read the saved installer ID.'
[[ "$software_show" == *'HTTPS and archive validation; no published checksum'* ]] \
  || fail 'Software show did not disclose the installer verification level.'

# A non-interactive run may not silently accept a vendor artifact that has no
# published checksum. Report Discord as absent through the fake dpkg-query and
# prove the guard stops before sudo, download, or installer execution.
cp -- "$TEST_REMOTE/TESTHOST/.mint-jelly/recovery.manifest" \
  "$TEST_ROOT/recovery.manifest.before-weak-check"
sed -i 's/^installer=.*/installer=discord/' \
  "$TEST_REMOTE/TESTHOST/.mint-jelly/recovery.manifest"
if weak_verification_error="$(
  MINT_JELLY_OS_RELEASE_FILE="$PROJECT_ROOT/tests/fixtures/os-release" \
  PATH="$PROJECT_ROOT/tests/fakes:$TEST_BIN:/usr/bin:/bin" \
    "$LAUNCHER" software install --remote alpha --source-host TESTHOST \
      --installers-only --yes 2>&1
)"; then
  fail 'Unattended software install accepted a limited-verification artifact without explicit consent.'
fi
[[ "$weak_verification_error" == *'requires --allow-weak-verification: discord'* ]] \
  || fail "Limited-verification refusal failed unclearly: $weak_verification_error"
mv -f -- "$TEST_ROOT/recovery.manifest.before-weak-check" \
  "$TEST_REMOTE/TESTHOST/.mint-jelly/recovery.manifest"

if "$LAUNCHER" software install --allow-weak-verification \
  >/dev/null 2>&1; then
  fail '--allow-weak-verification was accepted without --yes.'
fi
if "$LAUNCHER" software install --apt-only --yes --allow-weak-verification \
  >/dev/null 2>&1; then
  fail '--allow-weak-verification was accepted for an APT-only run.'
fi

cp -- "$TEST_REMOTE/TESTHOST/.mint-jelly/recovery.manifest" \
  "$TEST_ROOT/recovery.manifest.valid"
truncate -s 2097152 "$TEST_REMOTE/TESTHOST/.mint-jelly/recovery.manifest"
if "$LAUNCHER" software show --remote alpha --source-host TESTHOST \
  >/dev/null 2>&1; then
  fail 'Software read accepted an oversized remote recovery manifest.'
fi
mv -f -- "$TEST_ROOT/recovery.manifest.valid" \
  "$TEST_REMOTE/TESTHOST/.mint-jelly/recovery.manifest"

if query_error="$(
  MINT_JELLY_TEST_DPKG_QUERY_ERROR=true \
  MINT_JELLY_OS_RELEASE_FILE="$PROJECT_ROOT/tests/fixtures/os-release" \
  PATH="$PROJECT_ROOT/tests/fakes:$TEST_BIN:/usr/bin:/bin" \
    "$LAUNCHER" software show --remote alpha --source-host TESTHOST 2>&1
)"; then
  fail 'Software show treated a dpkg-query database error as a missing package.'
fi
[[ "$query_error" == *"dpkg-query failed for 'mint-jelly-test-package' with status 2"* ]] \
  || fail "Software show hid the dpkg-query failure: $query_error"

TEST_APT_LOG="$TEST_ROOT/apt.log"
export MINT_JELLY_TEST_LOG="$TEST_APT_LOG"
MINT_JELLY_OS_RELEASE_FILE="$PROJECT_ROOT/tests/fixtures/os-release" \
PATH="$PROJECT_ROOT/tests/fakes:$TEST_BIN:/usr/bin:/bin" \
  "$LAUNCHER" software install --remote alpha --source-host TESTHOST \
    --apt-only --yes >/dev/null
grep -qx 'apt-get -o Dpkg::Use-Pty=0 update' "$TEST_APT_LOG" \
  || fail 'Software install did not refresh APT indexes.'
grep -qx 'apt-get -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confold install --yes mint-jelly-test-package' "$TEST_APT_LOG" \
  || fail 'Software install did not use the expected APT package transaction.'

"$LAUNCHER" uninstall --yes >/dev/null
assert_not_exists "$TEST_DATA/mint-jelly"
assert_not_exists "$LAUNCHER"
assert_not_exists "$COMPLETION"
assert_file "$TEST_CONFIG/mint-jelly/backup.conf"
[[ -d "$TEST_STATE/mint-jelly" ]] || fail 'State directory should survive a normal uninstall.'

run_installer
"$LAUNCHER" uninstall --purge --yes >/dev/null
assert_not_exists "$TEST_CONFIG/mint-jelly"
assert_not_exists "$TEST_STATE/mint-jelly"

printf 'All Mint Jelly tests passed.\n'
