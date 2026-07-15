#!/usr/bin/env bash

# Authoritative recovery-domain registry. Domain entry points use this order for
# capture and manifest loading; restore phases may deliberately apply data in a
# different order (software installation must precede user data, for example).

MINT_JELLY_DOMAINS=(files software repositories system-settings)

domain_exists() {
  local wanted="$1" domain

  [[ "$wanted" == 'all' ]] && return 0
  for domain in "${MINT_JELLY_DOMAINS[@]}"; do
    [[ "$domain" == "$wanted" ]] && return 0
  done
  return 1
}

domain_is_selected() {
  local selected="$1" candidate="$2"

  [[ "$selected" == 'all' || "$selected" == "$candidate" ]]
}

domain_function_suffix() {
  printf '%s' "${1//-/_}"
}

domain_list_pipe_separated() {
  local IFS='|'
  printf '%s' "${MINT_JELLY_DOMAINS[*]}"
}
