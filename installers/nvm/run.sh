#!/usr/bin/env bash

set -Eeuo pipefail

readonly INSTALLER_NAME='NVM'
readonly RELEASE_API='https://api.github.com/repos/nvm-sh/nvm/releases/latest'
readonly REPOSITORY_URL='https://github.com/nvm-sh/nvm.git'
readonly RAW_BASE_URL='https://raw.githubusercontent.com/nvm-sh/nvm'
readonly MAX_METADATA_BYTES='10485760'
readonly MAX_SCRIPT_BYTES='131072'

if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
  [[ "$XDG_CONFIG_HOME" == /* && "$XDG_CONFIG_HOME" != '/' \
    && "$XDG_CONFIG_HOME" != *$'\n'* && "$XDG_CONFIG_HOME" != *$'\r'* \
    && "$XDG_CONFIG_HOME" != *'"'* && "$XDG_CONFIG_HOME" != *'\'* \
    && "$XDG_CONFIG_HOME" != *'$'* && "$XDG_CONFIG_HOME" != *'`'* ]] || {
    printf 'Error: XDG_CONFIG_HOME is unsafe for NVM profile integration.\n' >&2
    exit 2
  }
  readonly NVM_INSTALL_DIR="$XDG_CONFIG_HOME/nvm"
else
  readonly NVM_INSTALL_DIR="$HOME/.nvm"
fi
readonly PROFILE_FILE="$HOME/.bashrc"

TEMP_DIR=''
NVM_INSPECT_VERSION=''
NVM_INSPECT_COMMIT=''

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

path_is_user_owned() {
  [[ "$(stat -c '%u' -- "$1" 2>/dev/null)" == "$EUID" ]]
}

private_primary_group_is_safe() {
  local gid group_record group_members primary_users

  gid="$(id -g)" || return 1
  primary_users="$(awk -F: -v wanted_gid="$gid" \
    '$4 == wanted_gid { print $1 }' /etc/passwd 2>/dev/null)" || return 1
  [[ "$primary_users" == "$(id -un)" ]] || return 1
  group_record="$(getent group "$gid" 2>/dev/null)" || return 1
  group_members="${group_record##*:}"
  [[ -z "$group_members" || "$group_members" == "$(id -un)" ]]
}

inspect_path_mode() {
  local path="$1"
  local mode permissions

  mode="$(stat -c '%a' -- "$path" 2>/dev/null)" || return 2
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 2
  permissions=$((8#$mode))
  (( (permissions & 8#002) == 0 )) || return 2
  if (( (permissions & 8#020) != 0 )); then
    private_primary_group_is_safe || return 2
  fi
  return 0
}

read_package_version() {
  local package_file="$1"
  local contents pattern

  [[ -f "$package_file" && ! -L "$package_file" ]] || return 1
  contents="$(<"$package_file")"
  pattern='"version"[[:space:]]*:[[:space:]]*"([0-9]+([.][0-9]+)+)"'
  [[ "$contents" =~ $pattern ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

inspect_nvm_installation() {
  local actual_version commit remote version
  local group_writable_git world_writable_git wrong_owner_git custom_hook unsafe_git_config

  NVM_INSPECT_VERSION=''
  NVM_INSPECT_COMMIT=''
  if [[ ! -e "$NVM_INSTALL_DIR" && ! -L "$NVM_INSTALL_DIR" ]]; then
    return 1
  fi
  [[ -d "$NVM_INSTALL_DIR" && ! -L "$NVM_INSTALL_DIR" ]] || {
    printf 'Error: NVM installation path is not a safe directory: %s\n' "$NVM_INSTALL_DIR" >&2
    return 2
  }
  path_is_user_owned "$NVM_INSTALL_DIR" || {
    printf 'Error: NVM installation is not owned by the current user: %s\n' "$NVM_INSTALL_DIR" >&2
    return 2
  }

  for path in \
    "$NVM_INSTALL_DIR/nvm.sh" \
    "$NVM_INSTALL_DIR/nvm-exec" \
    "$NVM_INSTALL_DIR/bash_completion" \
    "$NVM_INSTALL_DIR/package.json"; do
    [[ -f "$path" && ! -L "$path" ]] || {
      printf 'Error: NVM installation is incomplete or unsafe: %s\n' "$path" >&2
      return 2
    }
    path_is_user_owned "$path" || {
      printf 'Error: NVM runtime file is not owned by the current user: %s\n' "$path" >&2
      return 2
    }
    inspect_path_mode "$path" || {
      printf 'Error: NVM runtime file has unsafe permissions: %s\n' "$path" >&2
      return 2
    }
  done
  [[ -x "$NVM_INSTALL_DIR/nvm.sh" && -x "$NVM_INSTALL_DIR/nvm-exec" ]] || {
    printf 'Error: NVM runtime scripts are not executable.\n' >&2
    return 2
  }

  inspect_path_mode "$NVM_INSTALL_DIR" || {
    printf 'Error: NVM installation directory has unsafe permissions.\n' >&2
    return 2
  }

  [[ -d "$NVM_INSTALL_DIR/.git" && ! -L "$NVM_INSTALL_DIR/.git" ]] || {
    printf 'Error: NVM installation is not an official Git checkout.\n' >&2
    return 2
  }
  wrong_owner_git="$(find "$NVM_INSTALL_DIR/.git" -xdev ! -user "$(id -un)" -print -quit)"
  [[ -z "$wrong_owner_git" ]] || {
    printf 'Error: NVM Git metadata contains files not owned by the current user.\n' >&2
    return 2
  }
  world_writable_git="$(find "$NVM_INSTALL_DIR/.git" -xdev -perm -0002 -print -quit)"
  [[ -z "$world_writable_git" ]] || {
    printf 'Error: NVM Git metadata is world-writable: %s\n' "$world_writable_git" >&2
    return 2
  }
  group_writable_git="$(find "$NVM_INSTALL_DIR/.git" -xdev -perm -0020 -print -quit)"
  if [[ -n "$group_writable_git" ]]; then
    private_primary_group_is_safe || {
      printf 'Error: NVM Git metadata is writable by an unsafe group.\n' >&2
      return 2
    }
  fi
  custom_hook="$(find "$NVM_INSTALL_DIR/.git/hooks" -maxdepth 1 -type f \
    ! -name '*.sample' -print -quit 2>/dev/null || true)"
  [[ -z "$custom_hook" ]] || {
    printf 'Error: NVM Git checkout contains an unexpected hook: %s\n' "$custom_hook" >&2
    return 2
  }
  unsafe_git_config="$(git -C "$NVM_INSTALL_DIR" config --local --name-only \
    --get-regexp '^(include|filter|credential|url[.]|http[.]|core[.]hookspath)' \
    2>/dev/null || true)"
  [[ -z "$unsafe_git_config" ]] || {
    printf 'Error: NVM Git checkout contains unsafe local configuration: %s\n' \
      "$unsafe_git_config" >&2
    return 2
  }

  remote="$(git -C "$NVM_INSTALL_DIR" remote get-url origin 2>/dev/null || true)"
  [[ "$remote" == "$REPOSITORY_URL" ]] || {
    printf 'Error: NVM Git origin is unexpected: %s\n' "${remote:-missing}" >&2
    return 2
  }
  [[ -z "$(git -C "$NVM_INSTALL_DIR" status --porcelain --untracked-files=no 2>/dev/null)" ]] || {
    printf 'Error: NVM Git checkout contains modified tracked files.\n' >&2
    return 2
  }
  git -C "$NVM_INSTALL_DIR" fsck --no-dangling >/dev/null 2>&1 || {
    printf 'Error: NVM Git checkout failed repository integrity verification.\n' >&2
    return 2
  }
  commit="$(git -C "$NVM_INSTALL_DIR" rev-parse HEAD 2>/dev/null || true)"
  [[ "$commit" =~ ^[A-Fa-f0-9]{40}$ ]] || {
    printf 'Error: NVM Git checkout has an invalid commit.\n' >&2
    return 2
  }
  version="$(read_package_version "$NVM_INSTALL_DIR/package.json" || true)"
  [[ -n "$version" ]] || {
    printf 'Error: NVM package metadata has no valid version.\n' >&2
    return 2
  }
  actual_version="$(env NVM_DIR="$NVM_INSTALL_DIR" \
    bash --noprofile --norc -c '. "$NVM_DIR/nvm.sh"; nvm --version' 2>/dev/null || true)"
  [[ "$actual_version" == "$version" ]] || {
    printf 'Error: NVM runtime version does not match its package metadata.\n' >&2
    return 2
  }

  NVM_INSPECT_VERSION="$version"
  NVM_INSPECT_COMMIT="${commit,,}"
}

profile_install_dir() {
  if [[ "$NVM_INSTALL_DIR" == "$HOME"/* ]]; then
    printf '$HOME/%s' "${NVM_INSTALL_DIR#"$HOME"/}"
  else
    printf '%s' "$NVM_INSTALL_DIR"
  fi
}

profile_expected_lines() {
  local install_dir

  install_dir="$(profile_install_dir)"
  printf 'export NVM_DIR="%s"\n' "$install_dir"
  printf '%s\n' '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm'
  printf '%s\n' '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion'
}

profile_status() {
  local expected nvm_dir_line source_line completion_line line count
  local -a expected_lines=()

  if [[ ! -e "$PROFILE_FILE" && ! -L "$PROFILE_FILE" ]]; then
    return 1
  fi
  [[ -f "$PROFILE_FILE" && ! -L "$PROFILE_FILE" ]] || {
    printf 'Error: Bash profile is not a safe regular file: %s\n' "$PROFILE_FILE" >&2
    return 2
  }
  path_is_user_owned "$PROFILE_FILE" || {
    printf 'Error: Bash profile is not owned by the current user: %s\n' "$PROFILE_FILE" >&2
    return 2
  }
  if inspect_path_mode "$PROFILE_FILE"; then
    :
  else
    printf 'Error: Bash profile has unsafe write permissions: %s\n' "$PROFILE_FILE" >&2
    return 2
  fi

  expected="$(profile_expected_lines)"
  mapfile -t expected_lines <<< "$expected"
  nvm_dir_line="${expected_lines[0]}"
  source_line="${expected_lines[1]}"
  completion_line="${expected_lines[2]}"

  for line in "$nvm_dir_line" "$source_line" "$completion_line"; do
    count="$(grep -Fxc -- "$line" "$PROFILE_FILE" || true)"
    [[ "$count" =~ ^[0-9]+$ ]] || return 2
    ((count <= 1)) || {
      printf 'Error: Bash profile contains duplicate NVM loader lines.\n' >&2
      return 2
    }
  done
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == "$nvm_dir_line" ]] || {
      printf 'Error: Bash profile contains a conflicting NVM_DIR definition.\n' >&2
      return 2
    }
  done < <(grep -F 'NVM_DIR=' "$PROFILE_FILE" || true)
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == "$source_line" ]] || {
      printf 'Error: Bash profile contains a conflicting NVM source line.\n' >&2
      return 2
    }
  done < <(grep -F '/nvm.sh' "$PROFILE_FILE" || true)
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == "$completion_line" ]] || {
      printf 'Error: Bash profile contains a conflicting NVM completion line.\n' >&2
      return 2
    }
  done < <(grep -F '$NVM_DIR/bash_completion' "$PROFILE_FILE" || true)

  grep -Fqx -- "$nvm_dir_line" "$PROFILE_FILE" \
    && grep -Fqx -- "$source_line" "$PROFILE_FILE" \
    && grep -Fqx -- "$completion_line" "$PROFILE_FILE"
}

check_installation() {
  local command nvm_status profile_result

  for command in awk bash find getent git grep id stat; do
    command -v "$command" >/dev/null 2>&1 || {
      printf 'Error: Required command not found: %s\n' "$command" >&2
      return 2
    }
  done

  if inspect_nvm_installation; then
    nvm_status=0
  else
    nvm_status=$?
  fi
  ((nvm_status <= 1)) || return "$nvm_status"

  if profile_status; then
    profile_result=0
  else
    profile_result=$?
  fi
  ((profile_result <= 1)) || return "$profile_result"
  ((nvm_status == 0 && profile_result == 0))
}

verify_installation() {
  local rc

  if check_installation; then
    :
  else
    rc=$?
    if ((rc == 1)); then
      printf '%s is not fully installed or requires a safe configuration repair.\n' \
        "$INSTALLER_NAME" >&2
    fi
    return "$rc"
  fi
  printf '%s is installed (version %s at %s).\n' \
    "$INSTALLER_NAME" "$NVM_INSPECT_VERSION" "$NVM_INSTALL_DIR"
}

parse_release_metadata() {
  local metadata_file="$1"

  python3 - "$metadata_file" <<'PY'
import json
import re
import sys

with open(sys.argv[1], "r", encoding="utf-8") as stream:
    release = json.load(stream)

tag = str(release.get("tag_name", ""))
if release.get("draft") is not False or release.get("prerelease") is not False:
    raise SystemExit("latest NVM release is not stable")
if not re.fullmatch(r"v[0-9]+(?:[.][0-9]+)+", tag):
    raise SystemExit("invalid NVM release tag")
if release.get("html_url") != f"https://github.com/nvm-sh/nvm/releases/tag/{tag}":
    raise SystemExit("unexpected NVM release URL")

print(tag)
PY
}

resolve_release_commit() {
  local tag="$1"
  local ref="refs/tags/$tag"
  local sha name tag_sha='' peeled_sha=''
  local output

  output="$(env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_COUNT=0 git ls-remote "$REPOSITORY_URL" "$ref" "$ref^{}")" \
    || return 1
  while IFS=$'\t' read -r sha name; do
    [[ "$sha" =~ ^[A-Fa-f0-9]{40}$ ]] || return 1
    case "$name" in
      "$ref") tag_sha="${sha,,}" ;;
      "$ref^{}") peeled_sha="${sha,,}" ;;
      *) return 1 ;;
    esac
  done <<< "$output"
  [[ -n "$tag_sha" ]] || return 1
  printf '%s\n' "${peeled_sha:-$tag_sha}"
}

validate_install_script() {
  local script_file="$1"
  local tag="$2"

  python3 - "$script_file" "$tag" "$MAX_SCRIPT_BYTES" <<'PY' || return 1
import sys

path, tag = sys.argv[1:3]
maximum = int(sys.argv[3])
data = open(path, "rb").read(maximum + 1)
if not data or len(data) > maximum:
    raise SystemExit("install script is empty or exceeds the safety limit")
if b"\x00" in data or b"\r" in data:
    raise SystemExit("install script contains forbidden bytes")
text = data.decode("utf-8")
required = (
    "#!/usr/bin/env bash\n",
    "{ # this ensures the entire script is downloaded #",
    "nvm_latest_version()",
    f'nvm_echo "{tag}"',
    "NVM_INSTALL_GITHUB_REPO:-nvm-sh/nvm",
    "} # this ensures the entire script is downloaded #",
)
for value in required:
    if value not in text:
        raise SystemExit(f"install script is missing required identity marker: {value!r}")
if not text.rstrip().endswith("} # this ensures the entire script is downloaded #"):
    raise SystemExit("install script has an unexpected ending")
PY
  bash -n "$script_file"
}

harden_nvm_installation() {
  chmod go-w -- "$NVM_INSTALL_DIR"
  find "$NVM_INSTALL_DIR" -maxdepth 1 -type f -exec chmod go-w -- {} +
  chmod -R go-w -- "$NVM_INSTALL_DIR/.git"
}

ensure_profile_lines() {
  local expected line mode status temp_file
  local -a expected_lines=()

  if profile_status; then
    return 0
  else
    status=$?
    ((status == 1)) || return "$status"
  fi
  if [[ -e "$PROFILE_FILE" || -L "$PROFILE_FILE" ]]; then
    mode="$(stat -c '%a' -- "$PROFILE_FILE")" || return 1
  else
    mode='0644'
  fi
  temp_file="$(mktemp "$HOME/.mint-jelly-nvm-bashrc.XXXXXXXX")" || return 1
  if [[ -f "$PROFILE_FILE" ]]; then
    if ! cp -- "$PROFILE_FILE" "$temp_file"; then
      rm -f -- "$temp_file"
      return 1
    fi
  fi
  expected="$(profile_expected_lines)"
  mapfile -t expected_lines <<< "$expected"
  if ! printf '\n' >> "$temp_file"; then
    rm -f -- "$temp_file"
    return 1
  fi
  for line in "${expected_lines[@]}"; do
    if ! grep -Fqx -- "$line" "$temp_file" \
      && ! printf '%s\n' "$line" >> "$temp_file"; then
      rm -f -- "$temp_file"
      return 1
    fi
  done
  if ! chmod "$mode" -- "$temp_file" \
    || ! mv -f -- "$temp_file" "$PROFILE_FILE"; then
    rm -f -- "$temp_file"
    return 1
  fi
}

install_nvm() {
  local commit metadata_file metadata_output metadata_size raw_url rc script_file
  local script_size tag version
  local -a release_fields=()

  if check_installation; then
    log "$INSTALLER_NAME is already installed; skipping."
    return 0
  else
    rc=$?
    ((rc == 1)) || return "$rc"
  fi
  ((EUID != 0)) || die 'Run this installer as the desktop user, not as root'
  require_command awk
  require_command bash
  require_command chmod
  require_command cp
  require_command curl
  require_command find
  require_command getent
  require_command git
  require_command grep
  require_command id
  require_command mktemp
  require_command mv
  require_command python3
  require_command stat

  umask 022
  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mint-jelly-nvm.XXXXXXXX")"
  metadata_file="$TEMP_DIR/release.json"
  script_file="$TEMP_DIR/install.sh"

  log 'Resolving the latest stable NVM release from GitHub...'
  curl --disable --fail --show-error --silent --location \
    --retry 3 --retry-delay 2 \
    --max-filesize "$MAX_METADATA_BYTES" \
    --proto '=https' --proto-redir '=https' \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --user-agent 'mint-jelly-installer' \
    --output "$metadata_file" "$RELEASE_API"
  metadata_size="$(stat -c '%s' -- "$metadata_file")"
  [[ "$metadata_size" =~ ^[0-9]+$ ]] \
    && ((metadata_size > 0 && metadata_size <= MAX_METADATA_BYTES)) \
    || die 'GitHub NVM release metadata has an invalid size'
  if ! metadata_output="$(parse_release_metadata "$metadata_file")"; then
    die 'Could not validate the latest stable NVM release metadata'
  fi
  mapfile -t release_fields <<< "$metadata_output"
  ((${#release_fields[@]} == 1)) || die 'NVM release metadata was incomplete'
  tag="${release_fields[0]}"
  version="${tag#v}"
  commit="$(resolve_release_commit "$tag" || true)"
  [[ "$commit" =~ ^[a-f0-9]{40}$ ]] \
    || die "Could not resolve NVM release tag $tag to one Git commit"

  raw_url="$RAW_BASE_URL/$commit/install.sh"
  log "Downloading the official NVM $tag install script from commit $commit..."
  curl --disable --fail --show-error --silent --location \
    --retry 3 --retry-delay 2 \
    --max-filesize "$MAX_SCRIPT_BYTES" \
    --proto '=https' --proto-redir '=https' \
    --output "$script_file" "$raw_url"
  script_size="$(stat -c '%s' -- "$script_file")"
  [[ "$script_size" =~ ^[0-9]+$ ]] \
    && ((script_size > 0 && script_size <= MAX_SCRIPT_BYTES)) \
    || die 'Downloaded NVM install script has an invalid size'
  validate_install_script "$script_file" "$tag" \
    || die 'Downloaded NVM install script failed identity or syntax validation'
  chmod 0700 -- "$script_file"

  if [[ -d "$NVM_INSTALL_DIR" && ! -L "$NVM_INSTALL_DIR" ]]; then
    harden_nvm_installation
  fi
  log "Running the validated official NVM $tag install script..."
  env \
    HOME="$HOME" \
    NVM_DIR="$NVM_INSTALL_DIR" \
    PROFILE=/dev/null \
    METHOD=git \
    NVM_INSTALL_GITHUB_REPO=nvm-sh/nvm \
    NVM_INSTALL_VERSION="$tag" \
    NVM_SOURCE='' \
    NODE_VERSION='' \
    NVM_ENV='' \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_COUNT=0 \
    SHELL=/bin/bash \
    bash "$script_file"

  harden_nvm_installation
  ensure_profile_lines || die "Could not safely configure NVM in $PROFILE_FILE"
  if ! inspect_nvm_installation; then
    die 'Installed NVM files did not pass verification'
  fi
  [[ "$NVM_INSPECT_VERSION" == "$version" && "$NVM_INSPECT_COMMIT" == "$commit" ]] \
    || die 'Installed NVM version or Git commit does not match the resolved release'
  profile_status || die 'Installed NVM Bash profile integration did not pass verification'
  verify_installation
  log 'Open a new terminal, or source ~/.bashrc, before using nvm in the current shell.'
}

cleanup() {
  local status=$?

  trap - EXIT HUP INT TERM
  [[ -z "$TEMP_DIR" || ! -d "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"
  exit "$status"
}

usage() {
  printf 'Usage: %s {check|install|verify}\n' "${0##*/}" >&2
}

main() {
  trap cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  (($# == 1)) || {
    usage
    return 64
  }
  case "$1" in
    check) check_installation ;;
    install) install_nvm ;;
    verify) verify_installation ;;
    *)
      usage
      return 64
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
