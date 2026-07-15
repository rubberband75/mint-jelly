# Bash completion for Mint Jelly.

_mint_jelly_static_words() {
  mapfile -t COMPREPLY < <(compgen -W "$1" -- "$cur")
}

_mint_jelly_dynamic_values() {
  local kind="$1" candidate
  while IFS= read -r candidate; do
    [[ "$candidate" == "$cur"* ]] && COMPREPLY+=("$candidate")
  done < <(mint-jelly __complete "$kind" 2>/dev/null)
  return 0
}

_mint_jelly_remote_names() {
  _mint_jelly_dynamic_values remotes
}

_mint_jelly_apt_candidates() {
  if declare -F _xfunc >/dev/null 2>&1; then
    COMPREPLY=($(_xfunc apt-cache _apt_cache_packages 2>/dev/null))
  elif command -v apt-cache >/dev/null 2>&1; then
    mapfile -t COMPREPLY < <(apt-cache --no-generate pkgnames "$cur" 2>/dev/null)
  fi
}

_mint_jelly_flatpak_candidates() {
  local line='flatpak' quoted index has_scope='false'
  command -v flatpak >/dev/null 2>&1 || return 0
  for ((index = 2; index < ${#COMP_WORDS[@]}; index += 1)); do
    [[ "${COMP_WORDS[index]}" == '--user' || "${COMP_WORDS[index]}" == '--system' ]] \
      && has_scope='true'
  done
  [[ "$has_scope" == 'true' ]] || line+=' --user'
  for ((index = 2; index < ${#COMP_WORDS[@]}; index += 1)); do
    printf -v quoted '%q' "${COMP_WORDS[index]}"
    line+=" $quoted"
  done
  mapfile -t COMPREPLY < <(flatpak complete "$line" "${#line}" "$cur" 2>/dev/null)
}

_mint_jelly_remote_options() {
  if [[ "$prev" == '--remote' ]]; then
    _mint_jelly_remote_names
  elif [[ "$prev" == '--source-host' ]]; then
    _mint_jelly_static_words "$(hostname 2>/dev/null)"
  else
    _mint_jelly_static_words "$1"
  fi
}

_mint_jelly() {
  local cur prev command action config_command remote_command

  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev=''
  (( COMP_CWORD > 0 )) && prev="${COMP_WORDS[COMP_CWORD - 1]}"
  command="${COMP_WORDS[1]-}"
  action="${COMP_WORDS[2]-}"

  if (( COMP_CWORD == 1 )); then
    _mint_jelly_static_words 'backup restore files software system-settings apt flatpak config version uninstall help --help --version'
    return
  fi

  case "$command" in
    backup)
      _mint_jelly_remote_options '--remote --dry-run --help'
      ;;
    restore)
      _mint_jelly_remote_options '--remote --source-host --dry-run --yes --force --include-hardware --allow-platform-mismatch --allow-weak-verification --help'
      ;;
    software)
      if (( COMP_CWORD == 2 )); then
        _mint_jelly_static_words 'install update uninstall list config backup list-remote restore --help'
      elif [[ "$action" == 'install' || "$action" == 'update' ]]; then
        if [[ "$cur" == --* ]]; then
          _mint_jelly_static_words '--allow-weak-verification --help'
        else
          _mint_jelly_dynamic_values installer-catalog
        fi
      elif [[ "$action" == 'uninstall' ]]; then
        if [[ "$cur" == --* ]]; then
          _mint_jelly_static_words '--purge --yes --help'
        else
          _mint_jelly_dynamic_values installers
        fi
      elif [[ "$action" == 'backup' ]]; then
        _mint_jelly_remote_options '--remote --help'
      elif [[ "$action" == 'list-remote' ]]; then
        _mint_jelly_remote_options '--remote --source-host --help'
      elif [[ "$action" == 'restore' ]]; then
        _mint_jelly_remote_options '--remote --source-host --dry-run --yes --force --allow-platform-mismatch --allow-weak-verification --help'
      fi
      ;;
    files)
      if (( COMP_CWORD == 2 )); then
        _mint_jelly_static_words 'config add remove list list-remote backup restore --help'
      elif [[ "$action" == 'backup' ]]; then
        _mint_jelly_remote_options '--remote --dry-run --help'
      elif [[ "$action" == 'list-remote' ]]; then
        _mint_jelly_remote_options '--remote --source-host --help'
      elif [[ "$action" == 'restore' ]]; then
        _mint_jelly_remote_options '--remote --source-host --dry-run --yes --force --allow-platform-mismatch --help'
      fi
      ;;
    system-settings)
      if (( COMP_CWORD == 2 )); then
        _mint_jelly_static_words 'config list list-remote backup restore --help'
      elif [[ "$action" == 'backup' ]]; then
        _mint_jelly_remote_options '--remote --dry-run --help'
      elif [[ "$action" == 'list-remote' ]]; then
        _mint_jelly_remote_options '--remote --source-host --help'
      elif [[ "$action" == 'restore' ]]; then
        _mint_jelly_remote_options '--remote --source-host --dry-run --yes --force --include-hardware --allow-platform-mismatch --help'
      fi
      ;;
    apt)
      if (( COMP_CWORD == 2 )); then
        _mint_jelly_static_words 'install add remove list config --help'
      elif [[ "$action" == 'install' || "$action" == 'add' ]]; then
        if [[ "$cur" == --* ]]; then
          [[ "$action" == 'install' ]] && _mint_jelly_static_words '--yes --help'
        else
          _mint_jelly_apt_candidates
        fi
      elif [[ "$action" == 'remove' ]]; then
        _mint_jelly_dynamic_values apt-packages
      elif [[ "$action" == 'config' ]]; then
        _mint_jelly_static_words '--show-all --help'
      elif [[ "$action" == 'backup' ]]; then
        _mint_jelly_remote_options '--remote --help'
      elif [[ "$action" == 'list-remote' ]]; then
        _mint_jelly_remote_options '--remote --source-host --help'
      elif [[ "$action" == 'restore' ]]; then
        _mint_jelly_remote_options '--remote --source-host --dry-run --yes --allow-platform-mismatch --help'
      fi
      ;;
    flatpak)
      if (( COMP_CWORD == 2 )); then
        _mint_jelly_static_words 'install add remove list config --help'
      elif [[ "$action" == 'install' || "$action" == 'add' ]]; then
        if [[ "$cur" == --* ]]; then
          _mint_jelly_static_words '--user --system --yes --help'
        else
          _mint_jelly_flatpak_candidates
        fi
      elif [[ "$action" == 'remove' ]]; then
        _mint_jelly_dynamic_values flatpaks
      elif [[ "$action" == 'backup' ]]; then
        _mint_jelly_remote_options '--remote --help'
      elif [[ "$action" == 'list-remote' ]]; then
        _mint_jelly_remote_options '--remote --source-host --help'
      elif [[ "$action" == 'restore' ]]; then
        _mint_jelly_remote_options '--remote --source-host --dry-run --yes --allow-platform-mismatch --help'
      fi
      ;;
    config)
      config_command="${COMP_WORDS[2]-}"
      if (( COMP_CWORD == 2 )); then
        _mint_jelly_static_words 'init remote --help'
      elif [[ "$config_command" == 'remote' ]]; then
        remote_command="${COMP_WORDS[3]-}"
        if (( COMP_CWORD == 3 )); then
          _mint_jelly_static_words 'add list set-default test --help'
        elif (( COMP_CWORD == 4 )) \
          && [[ "$remote_command" == 'set-default' || "$remote_command" == 'test' ]]; then
          _mint_jelly_remote_names
        fi
      fi
      ;;
    uninstall)
      _mint_jelly_static_words '--purge --yes --help'
      ;;
  esac
}

complete -F _mint_jelly mint-jelly
