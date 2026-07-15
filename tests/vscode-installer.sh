#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mint-jelly-vscode-tests.XXXXXXXX")"

cleanup_test() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup_test EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# shellcheck source=/dev/null
source "$PROJECT_ROOT/installers/vscode/run.sh"

cat > "$TEST_ROOT/release.json" <<'JSON'
{
  "url": "https://vscode.download.prss.microsoft.com/dbazure/download/stable/0123456789abcdef0123456789abcdef01234567/code_1.2.3-1234567890_amd64.deb",
  "name": "1.2.3",
  "version": "0123456789abcdef0123456789abcdef01234567",
  "productVersion": "1.2.3",
  "sha256hash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "supportsFastUpdate": true
}
JSON
expected_release=$'1.2.3\n1.2.3-1234567890\nhttps://vscode.download.prss.microsoft.com/dbazure/download/stable/0123456789abcdef0123456789abcdef01234567/code_1.2.3-1234567890_amd64.deb\n0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
[[ "$(parse_release_metadata "$TEST_ROOT/release.json")" == "$expected_release" ]] \
  || fail 'VS Code installer rejected valid Microsoft release metadata.'

cat > "$TEST_ROOT/vscode.sources" <<'EOF'
### THIS FILE IS AUTOMATICALLY CONFIGURED ###
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/microsoft.gpg
EOF
validate_source_file "$TEST_ROOT/vscode.sources" \
  || fail 'VS Code installer rejected a valid package-generated APT source.'
printf 'Enabled: no\n' >> "$TEST_ROOT/vscode.sources"
if validate_source_file "$TEST_ROOT/vscode.sources"; then
  fail 'VS Code installer accepted an unexpected APT source field.'
fi

mkdir -p -- "$TEST_ROOT/bin"
printf 'fixture\n' > "$TEST_ROOT/microsoft.gpg"
cat > "$TEST_ROOT/bin/gpg" <<EOF
#!/usr/bin/env bash
printf '%s\n' \\
  'pub:-:2048:1:EB3E94ADBE1229CF:0:0::-:::scESC::::::23::0:' \\
  'fpr:::::::::$MICROSOFT_KEY_FINGERPRINT:' \\
  'uid:-::::0::0::Microsoft (Release signing) <gpgsecurity@microsoft.com>::::::::::0:'
EOF
chmod 0755 -- "$TEST_ROOT/bin/gpg"
PATH="$TEST_ROOT/bin:$PATH" validate_key_file "$TEST_ROOT/microsoft.gpg" \
  || fail "VS Code installer rejected Microsoft's pinned signing-key identity."

mkdir -p -- "$TEST_ROOT/package/DEBIAN" "$TEST_ROOT/package/usr/share/code"
cat > "$TEST_ROOT/package/DEBIAN/control" <<'EOF'
Package: code
Version: 1.2.3-1234567890
Architecture: amd64
Maintainer: Microsoft Corporation <vscode-linux@microsoft.com>
Homepage: https://code.visualstudio.com/
Description: Visual Studio Code test fixture
EOF
printf 'fixture\n' > "$TEST_ROOT/package/usr/share/code/code"
dpkg-deb --build "$TEST_ROOT/package" "$TEST_ROOT/code.deb" >/dev/null
validate_deb "$TEST_ROOT/code.deb" '1.2.3-1234567890'
if (validate_deb "$TEST_ROOT/code.deb" '9.9.9-1') >/dev/null 2>&1; then
  fail 'VS Code installer accepted a Debian package with the wrong version.'
fi

APPLICATIONS=()
INSTALLERS=(vscode)
APT_PACKAGES=()
FLATPAK_APPS=()
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/application-profiles.sh"
application_auto_select_profiles
[[ "${APPLICATIONS[*]}" == 'vscode' ]] \
  || fail 'Configuring VS Code did not select its application profile.'
[[ "${APPLICATION_PROFILE_PATHS[vscode]}" == *'~/.config/Code/User'* ]] \
  || fail 'VS Code profile does not include its user configuration.'
[[ "${APPLICATION_PROFILE_PATHS[vscode]}" != *'extensions'* ]] \
  || fail 'VS Code profile included installed extension payload state.'

if (
  package_is_installed() { return 1; }
  check_installation
) >/dev/null 2>&1; then
  fail 'VS Code installer reported success when the code package was absent.'
else
  status=$?
  ((status == 1)) \
    || fail "Absent VS Code package returned unexpected status $status."
fi

if check_installation; then
  verify_installation >/dev/null \
    || fail 'VS Code installer check passed but verification failed.'
else
  status=$?
  ((status == 1)) \
    || fail "VS Code installer check failed unexpectedly with status $status."
fi

printf 'Visual Studio Code installer tests passed.\n'
