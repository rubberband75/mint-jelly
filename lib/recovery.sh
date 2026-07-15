#!/usr/bin/env bash

# Strict reader/writer for Mint Jelly's unified recovery manifest.
#
# This file is a library. Source lib/common.sh before sourcing it; errors are
# reported through common.sh's die helper. Entry points remain responsible for
# enabling strict mode.
#
# Public data populated by recovery_read or prepared by a caller:
#   RECOVERY_FORMAT
#   RECOVERY_HOSTNAME
#   RECOVERY_OS_ID
#   RECOVERY_OS_VERSION
#   RECOVERY_UBUNTU_CODENAME
#   RECOVERY_ARCHITECTURE
#   RECOVERY_SOURCES[]
#   RECOVERY_BACKUP_PLUGINS[]
#   RECOVERY_APT_PACKAGES[]
#   RECOVERY_INSTALLERS[]
#
# Public API:
#   recovery_reset
#     Clear all manifest data and initialize format to 1.
#
#   recovery_populate_platform [HOSTNAME]
#     Populate hostname and platform fields from HOSTNAME (or `hostname`),
#     /etc/os-release, and `dpkg --print-architecture`. Tests may override the
#     os-release path with MINT_JELLY_OS_RELEASE_FILE.
#
#   recovery_validate
#     Validate all public fields and arrays. Invalid or duplicate data is fatal.
#
#   recovery_read FILE
#     Parse FILE as inert key=value data. The file is never sourced or eval'd.
#
#   recovery_write_stdout
#     Validate and emit the canonical manifest to stdout.
#
#   recovery_write_file FILE
#     Validate and atomically replace FILE with a mode-0600 manifest. FILE's
#     parent directory must already exist.
#
#   recovery_write [FILE|-]
#     Convenience wrapper. With no argument or `-`, write to stdout; otherwise
#     atomically write FILE.

# Bounds are intentionally fixed rather than configurable from a recovery
# manifest. They keep a damaged or hostile remote from turning parsing into an
# unbounded disk, memory, or CPU operation.
RECOVERY_MANIFEST_MAX_BYTES=1048576
RECOVERY_MANIFEST_MAX_LINE_BYTES=4096
RECOVERY_MANIFEST_MAX_LINES=4096
RECOVERY_MANIFEST_MAX_SOURCES=256
RECOVERY_MANIFEST_MAX_BACKUP_PLUGINS=64
RECOVERY_MANIFEST_MAX_APT_PACKAGES=2048
RECOVERY_MANIFEST_MAX_INSTALLERS=128

RECOVERY_FORMAT='1'
RECOVERY_HOSTNAME=''
RECOVERY_OS_ID=''
RECOVERY_OS_VERSION=''
RECOVERY_UBUNTU_CODENAME=''
RECOVERY_ARCHITECTURE=''
RECOVERY_SOURCES=()
RECOVERY_BACKUP_PLUGINS=()
RECOVERY_APT_PACKAGES=()
RECOVERY_INSTALLERS=()

recovery_reset() {
  RECOVERY_FORMAT='1'
  RECOVERY_HOSTNAME=''
  RECOVERY_OS_ID=''
  RECOVERY_OS_VERSION=''
  RECOVERY_UBUNTU_CODENAME=''
  RECOVERY_ARCHITECTURE=''
  RECOVERY_SOURCES=()
  RECOVERY_BACKUP_PLUGINS=()
  RECOVERY_APT_PACKAGES=()
  RECOVERY_INSTALLERS=()
}

_recovery_has_control_character() {
  local value="$1"

  [[ "$value" =~ [[:cntrl:]] ]]
}

_recovery_validate_platform_name() {
  local value="$1"

  [[ "$value" =~ ^[a-z0-9][a-z0-9._-]*$ ]]
}

_recovery_validate_os_version() {
  local value="$1"

  [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._+~-]*$ ]]
}

_recovery_validate_package() {
  local value="$1"

  # Accept a Debian binary package name and an optional architecture qualifier.
  # Deliberately reject versions, paths, globs, and command-line options.
  validate_apt_package_name "$value"
}

_recovery_validate_serialized_limits() {
  local value line
  local total_bytes=0
  local total_lines=0
  local LC_ALL=C
  local -a scalar_lines=(
    "format=$RECOVERY_FORMAT"
    "hostname=$RECOVERY_HOSTNAME"
    "os_id=$RECOVERY_OS_ID"
    "os_version=$RECOVERY_OS_VERSION"
    "ubuntu_codename=$RECOVERY_UBUNTU_CODENAME"
    "architecture=$RECOVERY_ARCHITECTURE"
  )

  (( ${#RECOVERY_SOURCES[@]} <= RECOVERY_MANIFEST_MAX_SOURCES )) \
    || die "Recovery manifest exceeds the $RECOVERY_MANIFEST_MAX_SOURCES-source limit."
  (( ${#RECOVERY_BACKUP_PLUGINS[@]} <= RECOVERY_MANIFEST_MAX_BACKUP_PLUGINS )) \
    || die "Recovery manifest exceeds the $RECOVERY_MANIFEST_MAX_BACKUP_PLUGINS-backup-plugin limit."
  (( ${#RECOVERY_APT_PACKAGES[@]} <= RECOVERY_MANIFEST_MAX_APT_PACKAGES )) \
    || die "Recovery manifest exceeds the $RECOVERY_MANIFEST_MAX_APT_PACKAGES-APT-package limit."
  (( ${#RECOVERY_INSTALLERS[@]} <= RECOVERY_MANIFEST_MAX_INSTALLERS )) \
    || die "Recovery manifest exceeds the $RECOVERY_MANIFEST_MAX_INSTALLERS-installer limit."

  total_lines=$((
    ${#scalar_lines[@]}
    + ${#RECOVERY_SOURCES[@]}
    + ${#RECOVERY_BACKUP_PLUGINS[@]}
    + ${#RECOVERY_APT_PACKAGES[@]}
    + ${#RECOVERY_INSTALLERS[@]}
  ))
  (( total_lines <= RECOVERY_MANIFEST_MAX_LINES )) \
    || die "Recovery manifest exceeds the $RECOVERY_MANIFEST_MAX_LINES-line limit."

  for line in "${scalar_lines[@]}"; do
    (( ${#line} <= RECOVERY_MANIFEST_MAX_LINE_BYTES )) \
      || die "Recovery manifest line exceeds $RECOVERY_MANIFEST_MAX_LINE_BYTES bytes."
    ((total_bytes += ${#line} + 1))
  done
  for value in "${RECOVERY_SOURCES[@]}"; do
    line="source=$value"
    (( ${#line} <= RECOVERY_MANIFEST_MAX_LINE_BYTES )) \
      || die "Recovery manifest source line exceeds $RECOVERY_MANIFEST_MAX_LINE_BYTES bytes."
    ((total_bytes += ${#line} + 1))
  done
  for value in "${RECOVERY_BACKUP_PLUGINS[@]}"; do
    line="backup_plugin=$value"
    (( ${#line} <= RECOVERY_MANIFEST_MAX_LINE_BYTES )) \
      || die "Recovery manifest backup_plugin line exceeds $RECOVERY_MANIFEST_MAX_LINE_BYTES bytes."
    ((total_bytes += ${#line} + 1))
  done
  for value in "${RECOVERY_APT_PACKAGES[@]}"; do
    line="apt_package=$value"
    (( ${#line} <= RECOVERY_MANIFEST_MAX_LINE_BYTES )) \
      || die "Recovery manifest apt_package line exceeds $RECOVERY_MANIFEST_MAX_LINE_BYTES bytes."
    ((total_bytes += ${#line} + 1))
  done
  for value in "${RECOVERY_INSTALLERS[@]}"; do
    line="installer=$value"
    (( ${#line} <= RECOVERY_MANIFEST_MAX_LINE_BYTES )) \
      || die "Recovery manifest installer line exceeds $RECOVERY_MANIFEST_MAX_LINE_BYTES bytes."
    ((total_bytes += ${#line} + 1))
  done
  (( total_bytes <= RECOVERY_MANIFEST_MAX_BYTES )) \
    || die "Recovery manifest exceeds the $RECOVERY_MANIFEST_MAX_BYTES-byte limit."
}

_recovery_decode_os_release_value() {
  local value="$1"

  # The platform identifiers used here never need shell interpolation. Accept
  # the three os-release quoting forms, then let field validation reject escape
  # sequences, whitespace, substitutions, and other unexpected content.
  if [[ "$value" == \"*\" && ${#value} -ge 2 ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" == \'*\' && ${#value} -ge 2 ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" == *\"* || "$value" == *\'* ]]; then
    return 1
  fi

  printf '%s' "$value"
}

_recovery_read_os_release_key() {
  local file="$1"
  local wanted_key="$2"
  local raw key encoded decoded found='false'

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    [[ "$raw" != *$'\r'* ]] || return 1
    [[ -z "$raw" || "$raw" == \#* ]] && continue
    [[ "$raw" == *=* ]] || continue

    key="${raw%%=*}"
    [[ "$key" == "$wanted_key" ]] || continue
    [[ "$found" == 'false' ]] || return 1
    encoded="${raw#*=}"
    decoded="$(_recovery_decode_os_release_value "$encoded")" || return 1
    found='true'
  done < "$file"

  [[ "$found" == 'true' ]] || return 1
  printf '%s' "$decoded"
}

recovery_populate_platform() {
  local supplied_hostname="${1-}"
  local os_release_file="${MINT_JELLY_OS_RELEASE_FILE:-/etc/os-release}"
  local value

  [[ -r "$os_release_file" ]] \
    || die "Cannot read operating-system metadata: $os_release_file"
  command -v dpkg >/dev/null 2>&1 \
    || die 'Required command not found: dpkg'

  if [[ -n "$supplied_hostname" ]]; then
    RECOVERY_HOSTNAME="$supplied_hostname"
  else
    command -v hostname >/dev/null 2>&1 \
      || die 'Required command not found: hostname'
    RECOVERY_HOSTNAME="$(hostname)" \
      || die 'Could not determine the local hostname.'
  fi

  value="$(_recovery_read_os_release_key "$os_release_file" ID)" \
    || die "$os_release_file does not contain one valid ID value."
  RECOVERY_OS_ID="$value"
  value="$(_recovery_read_os_release_key "$os_release_file" VERSION_ID)" \
    || die "$os_release_file does not contain one valid VERSION_ID value."
  RECOVERY_OS_VERSION="$value"
  value="$(_recovery_read_os_release_key "$os_release_file" UBUNTU_CODENAME)" \
    || die "$os_release_file does not contain one valid UBUNTU_CODENAME value."
  RECOVERY_UBUNTU_CODENAME="$value"
  RECOVERY_ARCHITECTURE="$(dpkg --print-architecture)" \
    || die 'Could not determine the dpkg architecture.'

  # Fail here rather than allowing invalid local metadata to reach a manifest.
  validate_safe_name "$RECOVERY_HOSTNAME" \
    || die "Unsafe local hostname: $RECOVERY_HOSTNAME"
  _recovery_validate_platform_name "$RECOVERY_OS_ID" \
    || die "Unsafe operating-system ID: $RECOVERY_OS_ID"
  _recovery_validate_os_version "$RECOVERY_OS_VERSION" \
    || die "Unsafe operating-system version: $RECOVERY_OS_VERSION"
  _recovery_validate_platform_name "$RECOVERY_UBUNTU_CODENAME" \
    || die "Unsafe Ubuntu codename: $RECOVERY_UBUNTU_CODENAME"
  _recovery_validate_platform_name "$RECOVERY_ARCHITECTURE" \
    || die "Unsafe dpkg architecture: $RECOVERY_ARCHITECTURE"
}

recovery_validate() {
  local value existing
  local -A seen_sources=()
  local -A seen_plugins=()
  local -A seen_packages=()
  local -A seen_installers=()

  [[ "$RECOVERY_FORMAT" == '1' ]] \
    || die "Unsupported recovery manifest format: $RECOVERY_FORMAT"
  validate_safe_name "$RECOVERY_HOSTNAME" \
    || die "Recovery manifest has an unsafe hostname: $RECOVERY_HOSTNAME"
  _recovery_validate_platform_name "$RECOVERY_OS_ID" \
    || die "Recovery manifest has an unsafe os_id: $RECOVERY_OS_ID"
  _recovery_validate_os_version "$RECOVERY_OS_VERSION" \
    || die "Recovery manifest has an unsafe os_version: $RECOVERY_OS_VERSION"
  _recovery_validate_platform_name "$RECOVERY_UBUNTU_CODENAME" \
    || die "Recovery manifest has an unsafe ubuntu_codename: $RECOVERY_UBUNTU_CODENAME"
  _recovery_validate_platform_name "$RECOVERY_ARCHITECTURE" \
    || die "Recovery manifest has an unsafe architecture: $RECOVERY_ARCHITECTURE"
  (( ${#RECOVERY_SOURCES[@]} > 0 )) \
    || die 'Recovery manifest must contain at least one source.'

  for value in "${RECOVERY_SOURCES[@]}"; do
    ! _recovery_has_control_character "$value" \
      && validate_absolute_path "$value" \
      || die "Recovery manifest has an unsafe source: $value"
    [[ -z "${seen_sources[$value]+set}" ]] \
      || die "Recovery manifest contains a duplicate source: $value"
    for existing in "${!seen_sources[@]}"; do
      [[ "$value" != "$existing/"* && "$existing" != "$value/"* ]] \
        || die "Recovery manifest contains overlapping sources: $existing and $value"
    done
    seen_sources["$value"]=1
  done

  for value in "${RECOVERY_BACKUP_PLUGINS[@]}"; do
    validate_safe_name "$value" \
      || die "Recovery manifest has an unsafe backup_plugin: $value"
    [[ -z "${seen_plugins[$value]+set}" ]] \
      || die "Recovery manifest contains a duplicate backup_plugin: $value"
    seen_plugins["$value"]=1
  done

  for value in "${RECOVERY_APT_PACKAGES[@]}"; do
    _recovery_validate_package "$value" \
      || die "Recovery manifest has an unsafe apt_package: $value"
    [[ -z "${seen_packages[$value]+set}" ]] \
      || die "Recovery manifest contains a duplicate apt_package: $value"
    seen_packages["$value"]=1
  done

  for value in "${RECOVERY_INSTALLERS[@]}"; do
    validate_safe_name "$value" \
      || die "Recovery manifest has an unsafe installer: $value"
    [[ -z "${seen_installers[$value]+set}" ]] \
      || die "Recovery manifest contains a duplicate installer: $value"
    seen_installers["$value"]=1
  done

  _recovery_validate_serialized_limits
}

recovery_read() {
  local file="$1"
  local raw key value byte_count nul_prefix line_number=0
  local LC_ALL=C
  local -A seen_singletons=()

  [[ -f "$file" && ! -L "$file" && -r "$file" ]] \
    || die "Recovery manifest does not exist or is not readable: $file"
  command -v wc >/dev/null 2>&1 \
    || die 'Required command not found: wc'
  byte_count="$(wc -c < "$file")" \
    || die "Could not measure recovery manifest: $file"
  byte_count="$(trim "$byte_count")"
  [[ "$byte_count" =~ ^(0|[1-9][0-9]*)$ ]] \
    || die "Could not determine recovery manifest size: $file"
  (( 10#$byte_count <= RECOVERY_MANIFEST_MAX_BYTES )) \
    || die "$file exceeds the $RECOVERY_MANIFEST_MAX_BYTES-byte recovery manifest limit."
  if IFS= read -r -d '' nul_prefix < "$file"; then
    die "$file contains a NUL byte, which is not allowed in a recovery manifest."
  fi
  recovery_reset

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    ((line_number += 1))
    (( line_number <= RECOVERY_MANIFEST_MAX_LINES )) \
      || die "$file exceeds the $RECOVERY_MANIFEST_MAX_LINES-line recovery manifest limit."
    (( ${#raw} <= RECOVERY_MANIFEST_MAX_LINE_BYTES )) \
      || die "$file:$line_number exceeds the $RECOVERY_MANIFEST_MAX_LINE_BYTES-byte line limit."
    [[ "$raw" != *$'\r'* ]] \
      || die "$file:$line_number: carriage returns are not allowed."
    [[ -n "$raw" ]] \
      || die "$file:$line_number: empty lines are not allowed."
    [[ "$raw" == *=* ]] \
      || die "$file:$line_number: expected key=value."

    key="${raw%%=*}"
    value="${raw#*=}"
    [[ -n "$key" && -n "$value" ]] \
      || die "$file:$line_number: keys and values cannot be empty."
    ! _recovery_has_control_character "$key" \
      && ! _recovery_has_control_character "$value" \
      || die "$file:$line_number: control characters are not allowed."

    case "$key" in
      format|hostname|os_id|os_version|ubuntu_codename|architecture)
        [[ -z "${seen_singletons[$key]+set}" ]] \
          || die "$file:$line_number: duplicate key '$key'."
        seen_singletons["$key"]=1
        case "$key" in
          format) RECOVERY_FORMAT="$value" ;;
          hostname) RECOVERY_HOSTNAME="$value" ;;
          os_id) RECOVERY_OS_ID="$value" ;;
          os_version) RECOVERY_OS_VERSION="$value" ;;
          ubuntu_codename) RECOVERY_UBUNTU_CODENAME="$value" ;;
          architecture) RECOVERY_ARCHITECTURE="$value" ;;
        esac
        ;;
      source)
        (( ${#RECOVERY_SOURCES[@]} < RECOVERY_MANIFEST_MAX_SOURCES )) \
          || die "$file:$line_number exceeds the source-entry limit."
        RECOVERY_SOURCES+=("$value")
        ;;
      backup_plugin)
        (( ${#RECOVERY_BACKUP_PLUGINS[@]} < RECOVERY_MANIFEST_MAX_BACKUP_PLUGINS )) \
          || die "$file:$line_number exceeds the backup_plugin-entry limit."
        RECOVERY_BACKUP_PLUGINS+=("$value")
        ;;
      apt_package)
        (( ${#RECOVERY_APT_PACKAGES[@]} < RECOVERY_MANIFEST_MAX_APT_PACKAGES )) \
          || die "$file:$line_number exceeds the apt_package-entry limit."
        RECOVERY_APT_PACKAGES+=("$value")
        ;;
      installer)
        (( ${#RECOVERY_INSTALLERS[@]} < RECOVERY_MANIFEST_MAX_INSTALLERS )) \
          || die "$file:$line_number exceeds the installer-entry limit."
        RECOVERY_INSTALLERS+=("$value")
        ;;
      *) die "$file:$line_number: unknown recovery manifest key '$key'." ;;
    esac
  done < "$file"

  for key in format hostname os_id os_version ubuntu_codename architecture; do
    [[ -n "${seen_singletons[$key]+set}" ]] \
      || die "$file: required key '$key' is missing."
  done
  recovery_validate
}

recovery_write_stdout() {
  local value

  recovery_validate
  printf 'format=%s\n' "$RECOVERY_FORMAT" || return 1
  printf 'hostname=%s\n' "$RECOVERY_HOSTNAME" || return 1
  printf 'os_id=%s\n' "$RECOVERY_OS_ID" || return 1
  printf 'os_version=%s\n' "$RECOVERY_OS_VERSION" || return 1
  printf 'ubuntu_codename=%s\n' "$RECOVERY_UBUNTU_CODENAME" || return 1
  printf 'architecture=%s\n' "$RECOVERY_ARCHITECTURE" || return 1
  for value in "${RECOVERY_SOURCES[@]}"; do
    printf 'source=%s\n' "$value" || return 1
  done
  for value in "${RECOVERY_BACKUP_PLUGINS[@]}"; do
    printf 'backup_plugin=%s\n' "$value" || return 1
  done
  for value in "${RECOVERY_APT_PACKAGES[@]}"; do
    printf 'apt_package=%s\n' "$value" || return 1
  done
  for value in "${RECOVERY_INSTALLERS[@]}"; do
    printf 'installer=%s\n' "$value" || return 1
  done
}

recovery_write_file() {
  local file="$1"
  local directory basename temp_file

  [[ -n "$file" && "$file" != '-' && "$file" != */ ]] \
    || die 'A recovery manifest output file is required.'
  if [[ "$file" == */* ]]; then
    directory="${file%/*}"
    [[ -n "$directory" ]] || directory='/'
  else
    directory='.'
  fi
  basename="${file##*/}"
  [[ -d "$directory" ]] \
    || die "Recovery manifest directory does not exist: $directory"

  recovery_validate
  temp_file="$(mktemp -- "$directory/.${basename}.tmp.XXXXXX")" \
    || die "Could not create a temporary recovery manifest in: $directory"
  chmod 0600 -- "$temp_file" || {
    rm -f -- "$temp_file"
    die 'Could not secure the temporary recovery manifest.'
  }
  if ! recovery_write_stdout > "$temp_file"; then
    rm -f -- "$temp_file"
    die 'Could not write the temporary recovery manifest.'
  fi
  if ! mv -f -- "$temp_file" "$file"; then
    rm -f -- "$temp_file"
    die "Could not activate recovery manifest: $file"
  fi
  chmod 0600 -- "$file" \
    || die "Could not secure recovery manifest: $file"
}

recovery_write() {
  local file="${1--}"

  if [[ "$file" == '-' ]]; then
    recovery_write_stdout
  else
    recovery_write_file "$file"
  fi
}
