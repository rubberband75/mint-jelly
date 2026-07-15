#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mint-jelly-nvm-tests.XXXXXXXX")"

cleanup_test() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup_test EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

export HOME="$TEST_ROOT/home"
unset XDG_CONFIG_HOME
mkdir -p -- "$HOME"

# shellcheck source=/dev/null
source "$PROJECT_ROOT/installers/nvm/run.sh"

cat > "$TEST_ROOT/release.json" <<'JSON'
{
  "tag_name": "v9.8.7",
  "draft": false,
  "prerelease": false,
  "html_url": "https://github.com/nvm-sh/nvm/releases/tag/v9.8.7"
}
JSON
[[ "$(parse_release_metadata "$TEST_ROOT/release.json")" == 'v9.8.7' ]] \
  || fail 'NVM release parser rejected valid stable release metadata.'

cat > "$TEST_ROOT/install.sh" <<'SCRIPT'
#!/usr/bin/env bash
{ # this ensures the entire script is downloaded #
nvm_latest_version() {
  nvm_echo "v9.8.7"
}
repository="${NVM_INSTALL_GITHUB_REPO:-nvm-sh/nvm}"
: "$repository"
} # this ensures the entire script is downloaded #
SCRIPT
validate_install_script "$TEST_ROOT/install.sh" 'v9.8.7' \
  || fail 'NVM script validator rejected a structurally valid official-style script.'
if validate_install_script "$TEST_ROOT/install.sh" 'v1.0.0' >/dev/null 2>&1; then
  fail 'NVM script validator accepted a script for the wrong release.'
fi

if check_installation >/dev/null 2>&1; then
  fail 'NVM check reported an installation in an empty test home.'
else
  status=$?
  ((status == 1)) || fail "NVM absence check returned unexpected status $status."
fi

ensure_profile_lines || fail 'NVM installer could not create safe Bash profile integration.'
profile_status || fail 'NVM Bash profile integration did not pass validation.'
grep -Fqx 'export NVM_DIR="$HOME/.nvm"' "$HOME/.bashrc" \
  || fail 'NVM Bash profile used the wrong installation path.'

printf 'export NVM_DIR="/tmp/untrusted"\n' > "$HOME/.bashrc"
if profile_status >/dev/null 2>&1; then
  fail 'NVM profile validator accepted a conflicting NVM_DIR definition.'
else
  status=$?
  ((status == 2)) || fail "Conflicting NVM profile returned unexpected status $status."
fi

printf 'NVM installer tests passed.\n'
