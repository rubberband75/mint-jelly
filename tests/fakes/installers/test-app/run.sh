#!/usr/bin/env bash

set -euo pipefail

marker="${MINT_JELLY_TEST_INSTALL_MARKER:?}"

case "${1-}" in
  check)
    [[ -f "$marker" ]]
    ;;
  install)
    [[ "${MINT_JELLY_TEST_INSTALL_FAIL:-false}" != 'true' ]] || exit 1
    touch -- "$marker"
    ;;
  verify)
    [[ "${MINT_JELLY_TEST_VERIFY_FAIL:-false}" != 'true' && -f "$marker" ]]
    ;;
  *) exit 64 ;;
esac
