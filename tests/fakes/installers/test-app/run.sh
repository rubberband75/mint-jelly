#!/usr/bin/env bash

set -euo pipefail

marker="${MINT_JELLY_TEST_INSTALL_MARKER:?}"
[[ -z "${MINT_JELLY_TEST_ACTION_LOG:-}" ]] || printf '%s\n' "${1-}" >> "$MINT_JELLY_TEST_ACTION_LOG"

case "${1-}" in
  check)
    [[ -f "$marker" ]]
    ;;
  install)
    [[ "${MINT_JELLY_TEST_INSTALL_FAIL:-false}" != 'true' ]] || exit 1
    touch -- "$marker"
    ;;
  update)
    [[ -f "$marker" ]]
    touch -- "$marker"
    ;;
  uninstall)
    rm -f -- "$marker"
    [[ "${MINT_JELLY_PURGE:-false}" != true ]] || rm -f -- "${marker}.config"
    ;;
  verify)
    [[ "${MINT_JELLY_TEST_VERIFY_FAIL:-false}" != 'true' && -f "$marker" ]]
    ;;
  *) exit 64 ;;
esac
