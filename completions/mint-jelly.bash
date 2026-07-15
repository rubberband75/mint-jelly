# Bash completion for Mint Jelly.

_mint_jelly_static_words() {
  local words="$1"

  mapfile -t COMPREPLY < <(compgen -W "$words" -- "$cur")
}

_mint_jelly_remote_names() {
  local candidate

  while IFS= read -r candidate; do
    [[ "$candidate" == "$cur"* ]] && COMPREPLY+=("$candidate")
  done < <(mint-jelly __complete remotes 2>/dev/null)
}

_mint_jelly_config_values() {
  local kind="$1"
  local candidate

  while IFS= read -r candidate; do
    [[ "$candidate" == "$cur"* ]] && COMPREPLY+=("$candidate")
  done < <(mint-jelly __complete "$kind" 2>/dev/null)
}

_mint_jelly() {
  local cur prev command config_command remote_command

  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev=''
  (( COMP_CWORD > 0 )) && prev="${COMP_WORDS[COMP_CWORD - 1]}"
  command="${COMP_WORDS[1]-}"

  if (( COMP_CWORD == 1 )); then
    _mint_jelly_static_words 'backup restore software config version uninstall help --help --version'
    return
  fi

  case "$command" in
    backup)
      if [[ "$prev" == '--remote' ]]; then
        _mint_jelly_remote_names
      else
        _mint_jelly_static_words '--remote --dry-run --help'
      fi
      ;;
    restore)
      if [[ "$prev" == '--remote' ]]; then
        _mint_jelly_remote_names
      elif [[ "$prev" == '--source-host' ]]; then
        _mint_jelly_static_words "$(hostname 2>/dev/null)"
      else
        _mint_jelly_static_words '--remote --source-host --dry-run --yes --allow-platform-mismatch --help'
      fi
      ;;
    software)
      if [[ "$prev" == '--remote' ]]; then
        _mint_jelly_remote_names
      elif [[ "$prev" == '--source-host' ]]; then
        _mint_jelly_static_words "$(hostname 2>/dev/null)"
      elif (( COMP_CWORD == 2 )); then
        _mint_jelly_static_words 'show install --help'
      elif [[ "${COMP_WORDS[2]-}" == 'show' ]]; then
        _mint_jelly_static_words '--remote --source-host --help'
      else
        _mint_jelly_static_words '--remote --source-host --apt-only --installers-only --dry-run --yes --allow-platform-mismatch --allow-weak-verification --help'
      fi
      ;;
    config)
      config_command="${COMP_WORDS[2]-}"
      if (( COMP_CWORD == 2 )); then
        _mint_jelly_static_words 'init remote backup-plugins apt installers --help'
      elif [[ "$config_command" == 'remote' ]]; then
        remote_command="${COMP_WORDS[3]-}"
        if (( COMP_CWORD == 3 )); then
          _mint_jelly_static_words 'add list set-default test --help'
        elif (( COMP_CWORD == 4 )) \
          && [[ "$remote_command" == 'set-default' || "$remote_command" == 'test' ]]; then
          _mint_jelly_remote_names
        fi
      elif [[ "$config_command" == 'apt' ]]; then
        if (( COMP_CWORD == 3 )); then
          _mint_jelly_static_words 'list add remove select --help'
        elif [[ "${COMP_WORDS[3]-}" == 'remove' ]]; then
          _mint_jelly_config_values apt-packages
        fi
      fi
      ;;
    uninstall)
      _mint_jelly_static_words '--purge --yes --help'
      ;;
  esac
}

complete -F _mint_jelly mint-jelly
