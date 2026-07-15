#!/usr/bin/env bash
# End-to-end repository recovery test. The original Git remote is deliberately
# unavailable during restore so this exercises Mint Jelly's self-contained
# snapshot rather than GitHub-or-origin recovery.

set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mint-jelly-repositories-tests.XXXXXXXX")"
TEST_HOME="$TEST_ROOT/home"
TEST_DATA="$TEST_ROOT/data"
TEST_CONFIG="$TEST_ROOT/config"
TEST_STATE="$TEST_ROOT/state"
TEST_CACHE="$TEST_ROOT/cache"
TEST_BIN="$TEST_HOME/.local/bin"
TEST_REMOTE="$TEST_ROOT/backup-remote"
ORIGIN="$TEST_ROOT/origin.git"
REPOSITORY="$TEST_HOME/Development/Solle/docker"
SECOND_REPOSITORY="$TEST_HOME/Development/Secondary/project"

cleanup() { rm -rf -- "$TEST_ROOT"; }
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "Expected file: $1"
}

assert_directory() {
  [[ -d "$1" ]] || fail "Expected directory: $1"
}

assert_not_exists() {
  [[ ! -e "$1" && ! -L "$1" ]] || fail "Expected path to be absent: $1"
}

assert_equal() {
  [[ "$1" == "$2" ]] || fail "Expected '$2'; got '$1'"
}

assert_output_contains() {
  local output="$1" expected="$2"
  [[ "$output" == *"$expected"* ]] \
    || fail "Expected output to contain '$expected'; got: $output"
}

for command in git rsync; do
  command -v "$command" >/dev/null 2>&1 \
    || fail "Required test command is unavailable: $command"
done

mkdir -p -- "$TEST_HOME" "$TEST_DATA" "$TEST_CONFIG" "$TEST_STATE" \
  "$TEST_CACHE" "$TEST_REMOTE"

install_env=(
  HOME="$TEST_HOME"
  XDG_DATA_HOME="$TEST_DATA"
  XDG_CONFIG_HOME="$TEST_CONFIG"
  XDG_STATE_HOME="$TEST_STATE"
  XDG_CACHE_HOME="$TEST_CACHE"
  PATH=/usr/bin:/bin
)
env "${install_env[@]}" "$PROJECT_ROOT/install.sh" >/dev/null

LAUNCHER="$TEST_BIN/mint-jelly"
[[ -L "$LAUNCHER" && -x "$LAUNCHER" ]] \
  || fail 'Installer did not create an executable Mint Jelly launcher.'

export HOME="$TEST_HOME"
export XDG_DATA_HOME="$TEST_DATA"
export XDG_CONFIG_HOME="$TEST_CONFIG"
export XDG_STATE_HOME="$TEST_STATE"
export XDG_CACHE_HOME="$TEST_CACHE"
export PATH="$TEST_BIN:/usr/bin:/bin"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_TERMINAL_PROMPT=0

"$LAUNCHER" config init >/dev/null
grep -qx 'version=3' "$TEST_CONFIG/mint-jelly/config.ini" \
  || fail 'config init did not create configuration version 3.'

# Configure a deterministic local snapshot destination without depending on
# the interactive remote configurator.
bash -euo pipefail -c '
  script_dir=$1
  source "$script_dir/lib/common.sh"
  source "$script_dir/lib/config.sh"
  config_read
  config_add_remote_name recovery
  REMOTE_TYPE[recovery]=local
  REMOTE_ROOT_PATH[recovery]=$2
  DEFAULT_REMOTE=recovery
  FILE_SPECS=()
  APPLICATIONS=()
  SYSTEM_SETTINGS=()
  APT_PACKAGES=()
  FLATPAK_APPS=()
  INSTALLERS=()
  INSTALLER_OPTION_SELECTIONS=()
  config_write
' _ "$TEST_DATA/mint-jelly/current" "$TEST_REMOTE"

# Construct history which cannot be reconstructed from origin: an unpushed
# main commit, an unpushed branch, and a stash. Leave the worktree dirty as
# well, including a tracked deletion and ignored local configuration.
git init --bare "$ORIGIN" >/dev/null
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
mkdir -p -- "$REPOSITORY"
git init -b main "$REPOSITORY" >/dev/null
git -C "$REPOSITORY" config user.name 'Mint Jelly Test'
git -C "$REPOSITORY" config user.email 'mint-jelly@example.invalid'

printf '.env\n.vscode/\nnode_modules/\n' > "$REPOSITORY/.gitignore"
printf 'pushed content\n' > "$REPOSITORY/README.md"
printf 'delete me locally\n' > "$REPOSITORY/delete-me.txt"
git -C "$REPOSITORY" add .gitignore README.md delete-me.txt
git -C "$REPOSITORY" commit -m 'pushed commit' >/dev/null
git -C "$REPOSITORY" remote add origin "$ORIGIN"
git -C "$REPOSITORY" push -u origin main >/dev/null
git -C "$REPOSITORY" remote set-head origin main
PUSHED_COMMIT="$(git -C "$REPOSITORY" rev-parse HEAD)"

printf 'reachable only from the local main branch\n' > "$REPOSITORY/local-only.txt"
git -C "$REPOSITORY" add local-only.txt
git -C "$REPOSITORY" commit -m 'unpushed main commit' >/dev/null
UNPUSHED_MAIN_COMMIT="$(git -C "$REPOSITORY" rev-parse HEAD)"
[[ "$UNPUSHED_MAIN_COMMIT" != "$PUSHED_COMMIT" ]] \
  || fail 'Test fixture did not create an unpushed commit.'

git -C "$REPOSITORY" switch -c local-topic >/dev/null
printf 'reachable only from the local topic branch\n' > "$REPOSITORY/topic-only.txt"
git -C "$REPOSITORY" add topic-only.txt
git -C "$REPOSITORY" commit -m 'local topic commit' >/dev/null
LOCAL_TOPIC_COMMIT="$(git -C "$REPOSITORY" rev-parse HEAD)"
git -C "$REPOSITORY" switch main >/dev/null

printf 'temporarily stashed line\n' >> "$REPOSITORY/README.md"
printf 'temporarily stashed untracked file\n' > "$REPOSITORY/stashed-untracked.txt"
git -C "$REPOSITORY" stash push --include-untracked -m recovery-stash >/dev/null
OLDER_STASH_COMMIT="$(git -C "$REPOSITORY" rev-parse refs/stash)"
printf 'second stash line\n' >> "$REPOSITORY/README.md"
git -C "$REPOSITORY" stash push -m second-recovery-stash >/dev/null
STASH_COMMIT="$(git -C "$REPOSITORY" rev-parse refs/stash)"

printf 'dirty worktree content\n' > "$REPOSITORY/README.md"
rm -- "$REPOSITORY/delete-me.txt"
printf 'ordinary untracked content\n' > "$REPOSITORY/notes.txt"
mkdir -p -- "$REPOSITORY/.vscode" "$REPOSITORY/node_modules/example-package"
printf 'LOCAL_TOKEN=do-not-lose-this\n' > "$REPOSITORY/.env"
printf '{"editor.tabSize": 2}\n' > "$REPOSITORY/.vscode/settings.json"
printf 'generated dependency payload\n' \
  > "$REPOSITORY/node_modules/example-package/index.js"

"$LAUNCHER" repos add solle-docker "$REPOSITORY" >/dev/null
"$LAUNCHER" repos include solle-docker .env .vscode >/dev/null 2>&1
"$LAUNCHER" repos exclude solle-docker node_modules >/dev/null

repository_list="$("$LAUNCHER" repos list)"
assert_output_contains "$repository_list" $'solle-docker\t~/Development/Solle/docker'
assert_output_contains "$repository_list" $'include\t.env'
assert_output_contains "$repository_list" $'include\t.vscode'
assert_output_contains "$repository_list" $'exclude\tnode_modules'

# A partial generation cannot become the first current snapshot. Start with a
# full generation, then use the named command to exercise item-scoped updates.
if "$LAUNCHER" repos backup solle-docker >/dev/null 2>&1; then
  fail 'First-ever scoped repository backup was accepted.'
fi
"$LAUNCHER" backup >/dev/null
BACKED_HOST="$(hostname)"
CURRENT_FILE="$TEST_REMOTE/$BACKED_HOST/.mint-jelly/current"
assert_file "$CURRENT_FILE"
FIRST_GENERATION="$(<"$CURRENT_FILE")"
FIRST_SNAPSHOT="$TEST_REMOTE/$BACKED_HOST/.mint-jelly/snapshots/$FIRST_GENERATION"
assert_file "$FIRST_SNAPSHOT/repositories.manifest"

remote_plan="$("$LAUNCHER" repos list-remote)"
assert_output_contains "$remote_plan" 'Repositories:'
assert_output_contains "$remote_plan" "solle-docker: $REPOSITORY"

"$LAUNCHER" repos backup solle-docker >/dev/null
SECOND_GENERATION="$(<"$CURRENT_FILE")"
[[ "$SECOND_GENERATION" != "$FIRST_GENERATION" ]] \
  || fail 'Scoped repository backup did not create a second generation.'
SECOND_SNAPSHOT="$TEST_REMOTE/$BACKED_HOST/.mint-jelly/snapshots/$SECOND_GENERATION"
assert_file "$SECOND_SNAPSHOT/repositories.manifest"

mirror_objects="$FIRST_SNAPSHOT/data/repositories/solle-docker/repository.git/objects"
assert_directory "$mirror_objects"
first_object="$(find "$mirror_objects" -type f -print -quit)"
[[ -n "$first_object" ]] || fail 'Repository mirror does not contain any Git objects.'
relative_object="${first_object#"$FIRST_SNAPSHOT/data/repositories/"}"
second_object="$SECOND_SNAPSHOT/data/repositories/$relative_object"
assert_file "$second_object"
assert_equal "$(stat -c '%d:%i' -- "$second_object")" \
  "$(stat -c '%d:%i' -- "$first_object")"

# A named backup carries every untouched repository artifact and its capture
# metadata verbatim. It must not silently add a newly configured repository,
# apply that repository's later rule edits, or delete it after local removal.
mkdir -p -- "$SECOND_REPOSITORY"
git init -b main "$SECOND_REPOSITORY" >/dev/null
git -C "$SECOND_REPOSITORY" config user.name 'Mint Jelly Test'
git -C "$SECOND_REPOSITORY" config user.email 'mint-jelly@example.invalid'
printf '.env\n' > "$SECOND_REPOSITORY/.gitignore"
printf 'secondary repository\n' > "$SECOND_REPOSITORY/README.md"
printf 'SECONDARY_SECRET=preserve-policy\n' > "$SECOND_REPOSITORY/.env"
git -C "$SECOND_REPOSITORY" add .gitignore README.md
git -C "$SECOND_REPOSITORY" commit -m secondary >/dev/null
"$LAUNCHER" repos add secondary "$SECOND_REPOSITORY" >/dev/null
"$LAUNCHER" repos backup solle-docker >/dev/null
SCOPED_MANIFEST="$TEST_REMOTE/$BACKED_HOST/.mint-jelly/snapshots/$(<"$CURRENT_FILE")/repositories.manifest"
if grep -q '^repository=secondary|' "$SCOPED_MANIFEST"; then
  fail 'Scoped backup silently captured an unrequested new repository.'
fi

"$LAUNCHER" repos backup secondary >/dev/null
"$LAUNCHER" repos include secondary .env >/dev/null 2>&1
"$LAUNCHER" repos backup solle-docker >/dev/null
SCOPED_MANIFEST="$TEST_REMOTE/$BACKED_HOST/.mint-jelly/snapshots/$(<"$CURRENT_FILE")/repositories.manifest"
grep -q '^repository=secondary|' "$SCOPED_MANIFEST" \
  || fail 'Scoped backup dropped an untouched repository artifact.'
if grep -q '^include=secondary|' "$SCOPED_MANIFEST"; then
  fail 'Scoped backup paired old repository data with new include rules.'
fi

"$LAUNCHER" repos remove secondary >/dev/null
assert_not_exists "$TEST_CACHE/mint-jelly/repositories/secondary.git"
"$LAUNCHER" repos backup solle-docker >/dev/null
SCOPED_MANIFEST="$TEST_REMOTE/$BACKED_HOST/.mint-jelly/snapshots/$(<"$CURRENT_FILE")/repositories.manifest"
grep -q '^repository=secondary|' "$SCOPED_MANIFEST" \
  || fail 'Scoped backup deleted an untouched repository removed from local configuration.'

# Make origin unavailable and remove the entire source. A successful restore
# therefore proves that the snapshot contains both history and worktree data.
mv -- "$ORIGIN" "$TEST_ROOT/origin.unavailable"
if git ls-remote "$ORIGIN" >/dev/null 2>&1; then
  fail 'Test fixture origin is still accessible during offline restore.'
fi
rm -rf -- "$REPOSITORY"
"$LAUNCHER" repos restore solle-docker --yes >/dev/null

assert_directory "$REPOSITORY/.git"
assert_equal "$(git -C "$REPOSITORY" symbolic-ref --short HEAD)" main
assert_equal "$(git -C "$REPOSITORY" rev-parse HEAD)" "$UNPUSHED_MAIN_COMMIT"
assert_equal "$(git -C "$REPOSITORY" rev-parse refs/heads/local-topic)" \
  "$LOCAL_TOPIC_COMMIT"
assert_equal "$(git -C "$REPOSITORY" rev-parse refs/remotes/origin/main)" \
  "$PUSHED_COMMIT"
assert_equal "$(git -C "$REPOSITORY" rev-parse refs/stash)" "$STASH_COMMIT"
assert_equal "$(git -C "$REPOSITORY" rev-parse 'refs/stash@{1}')" "$OLDER_STASH_COMMIT"
assert_equal "$(git -C "$REPOSITORY" symbolic-ref refs/remotes/origin/HEAD)" \
  refs/remotes/origin/main
assert_equal "$(git -C "$REPOSITORY" remote get-url origin)" "$ORIGIN"
assert_equal "$(git -C "$REPOSITORY" config --get branch.main.remote)" origin
assert_equal "$(git -C "$REPOSITORY" config --get branch.main.merge)" refs/heads/main

grep -qx 'dirty worktree content' "$REPOSITORY/README.md" \
  || fail 'Restore did not reproduce the modified tracked file.'
grep -qx 'reachable only from the local main branch' "$REPOSITORY/local-only.txt" \
  || fail 'Restore omitted a file from the unpushed main commit.'
grep -qx 'ordinary untracked content' "$REPOSITORY/notes.txt" \
  || fail 'Restore omitted an ordinary untracked file.'
grep -qx 'LOCAL_TOKEN=do-not-lose-this' "$REPOSITORY/.env" \
  || fail 'Restore omitted the explicitly included ignored .env file.'
grep -Fxq '{"editor.tabSize": 2}' "$REPOSITORY/.vscode/settings.json" \
  || fail 'Restore omitted the explicitly included ignored .vscode directory.'
assert_not_exists "$REPOSITORY/delete-me.txt"
assert_not_exists "$REPOSITORY/node_modules"

status="$(git -C "$REPOSITORY" status --porcelain --untracked-files=all)"
assert_output_contains "$status" ' M README.md'
assert_output_contains "$status" ' D delete-me.txt'
assert_output_contains "$status" '?? notes.txt'

# Without --force an existing destination is preserved. With --force Mint
# Jelly replaces it from a fully assembled snapshot, restoring the dirty state
# again rather than merging into the existing worktree.
printf 'existing destination sentinel\n' > "$REPOSITORY/README.md"
"$LAUNCHER" repos restore solle-docker --yes >/dev/null 2>&1
grep -qx 'existing destination sentinel' "$REPOSITORY/README.md" \
  || fail 'Repository restore overwrote an existing destination without --force.'

"$LAUNCHER" repos restore solle-docker --yes --force >/dev/null
grep -qx 'dirty worktree content' "$REPOSITORY/README.md" \
  || fail 'Repository restore --force did not replace the existing destination.'
assert_equal "$(git -C "$REPOSITORY" rev-parse HEAD)" "$UNPUSHED_MAIN_COMMIT"
assert_equal "$(git -C "$REPOSITORY" rev-parse refs/stash)" "$STASH_COMMIT"
assert_equal "$(git -C "$REPOSITORY" rev-parse 'refs/stash@{1}')" "$OLDER_STASH_COMMIT"
assert_not_exists "$REPOSITORY/node_modules"

printf 'Repository recovery tests passed.\n'
