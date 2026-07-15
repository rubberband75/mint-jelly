#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mint-jelly-docker-tests.XXXXXXXX")"

cleanup_test() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup_test EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# shellcheck source=/dev/null
source "$PROJECT_ROOT/installers/docker-engine/run.sh"

cat > "$TEST_ROOT/os-release" <<'EOF'
NAME="Linux Mint"
VERSION_CODENAME=wilma
UBUNTU_CODENAME=noble
EOF

[[ "$(read_os_release_value UBUNTU_CODENAME "$TEST_ROOT/os-release")" == 'noble' ]] \
  || fail 'Docker installer did not read the Ubuntu base codename safely.'
[[ "$(expected_source_content amd64 noble)" == $'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: noble\nComponents: stable\nArchitectures: amd64\nSigned-By: /etc/apt/keyrings/docker.asc' ]] \
  || fail 'Docker installer generated the wrong deb822 repository source.'

for architecture in amd64 arm64 armhf s390x ppc64el; do
  architecture_is_supported "$architecture" \
    || fail "Docker installer rejected supported architecture: $architecture"
done
if architecture_is_supported i386; then
  fail 'Docker installer accepted unsupported i386 architecture.'
fi

mkdir -p -- "$TEST_ROOT/bin"
printf 'fixture\n' > "$TEST_ROOT/docker.asc"
cat > "$TEST_ROOT/bin/gpg" <<EOF
#!/usr/bin/env bash
printf '%s\n' \\
  'pub:-:4096:1:8D81803C0EBFCD88:0:0::-:::scESC::::::23::0:' \\
  'fpr:::::::::$DOCKER_KEY_FINGERPRINT:' \\
  'uid:-::::0::0::Docker Release (CE deb) <docker@docker.com>::::::::::0:'
EOF
chmod 0755 -- "$TEST_ROOT/bin/gpg"
PATH="$TEST_ROOT/bin:$PATH" validate_key_file "$TEST_ROOT/docker.asc" \
  || fail "Docker installer rejected Docker's pinned signing-key identity."

APPLICATIONS=()
INSTALLERS=(docker-engine)
APT_PACKAGES=()
FLATPAK_APPS=()
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/application-profiles.sh"
application_auto_select_profiles
[[ "${APPLICATIONS[*]}" == 'docker-engine' ]] \
  || fail 'Configuring Docker Engine did not select its CLI configuration profile.'
[[ "${APPLICATION_PROFILE_PATHS[docker-engine]}" == '~/.docker' ]] \
  || fail 'Docker Engine profile does not target the Docker CLI configuration.'

# This is read-only. It passes on a host whose existing Docker installation
# matches the complete Mint Jelly contract, and otherwise must report only
# "not configured" (1), never an unsafe or indeterminate status.
if check_installation; then
  verify_installation >/dev/null \
    || fail 'Docker installer check passed but verification failed.'
else
  status=$?
  ((status == 1)) \
    || fail "Docker installer check failed unexpectedly with status $status."
fi

printf 'Docker Engine installer tests passed.\n'
