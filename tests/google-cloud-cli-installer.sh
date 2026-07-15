#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# shellcheck source=/dev/null
source "$PROJECT_ROOT/installers/google-cloud-cli/run.sh"

load_selected_options
((${#INSTALL_PACKAGES[@]} == 1)) \
  || fail 'Google Cloud installer did not default to the base package only.'

MINT_JELLY_INSTALLER_OPTIONS="${ALLOWED_OPTIONS[*]}"
load_selected_options
((${#SELECTED_OPTIONS[@]} == 25)) \
  || fail 'Google Cloud installer did not accept all declared optional packages.'
((${#INSTALL_PACKAGES[@]} == 26)) \
  || fail 'Google Cloud installer did not include the base package with its options.'

if (
  MINT_JELLY_INSTALLER_OPTIONS='not-a-google-package'
  load_selected_options
) >/dev/null 2>&1; then
  fail 'Google Cloud installer accepted an undeclared optional package.'
fi

if "$PROJECT_ROOT/installers/google-cloud-cli/run.sh" \
  option-check not-a-google-package >/dev/null 2>&1; then
  fail 'Google Cloud option-check accepted an undeclared package.'
fi
if "$PROJECT_ROOT/installers/google-cloud-cli/run.sh" option-check kubectl \
  >/dev/null 2>&1; then
  :
else
  status=$?
  ((status == 1)) \
    || fail "Google Cloud option-check failed unexpectedly with status $status."
fi

# This check is read-only. A clean test host returns 1; a developer machine
# with the signed repository and base CLI already installed returns 0.
MINT_JELLY_INSTALLER_OPTIONS=''
if check_installation; then
  verify_installation >/dev/null \
    || fail 'Google Cloud installer check passed but verification failed.'
else
  status=$?
  ((status == 1)) \
    || fail "Google Cloud installer check failed unexpectedly with status $status."
fi

printf 'Google Cloud CLI installer tests passed.\n'
