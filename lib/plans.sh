#!/usr/bin/env bash

# Bounded, inert manifests for independently backed-up software domains.

PLAN_MAX_BYTES=1048576
PLAN_MAX_LINE_BYTES=4096
PLAN_MAX_LINES=4096
PLAN_MAX_ENTRIES=2048
PLAN_MAX_OPTIONS=512

PLAN_FORMAT='1'
PLAN_KIND=''
PLAN_HOSTNAME=''
PLAN_CREATED_AT=''
PLAN_OS_ID=''
PLAN_OS_VERSION=''
PLAN_UBUNTU_CODENAME=''
PLAN_ARCHITECTURE=''
PLAN_ENTRIES=()
PLAN_OPTIONS=()

plan_reset() {
  PLAN_FORMAT='1'
  PLAN_KIND=''
  PLAN_HOSTNAME=''
  PLAN_CREATED_AT=''
  PLAN_OS_ID=''
  PLAN_OS_VERSION=''
  PLAN_UBUNTU_CODENAME=''
  PLAN_ARCHITECTURE=''
  PLAN_ENTRIES=()
  PLAN_OPTIONS=()
}

plan_kind_is_valid() {
  case "$1" in
    software|apt|flatpak) return 0 ;;
    *) return 1 ;;
  esac
}

plan_populate_platform() {
  local hostname_value="$1"

  recovery_reset
  recovery_populate_platform "$hostname_value"
  PLAN_HOSTNAME="$RECOVERY_HOSTNAME"
  PLAN_CREATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  PLAN_OS_ID="$RECOVERY_OS_ID"
  PLAN_OS_VERSION="$RECOVERY_OS_VERSION"
  PLAN_UBUNTU_CODENAME="$RECOVERY_UBUNTU_CODENAME"
  PLAN_ARCHITECTURE="$RECOVERY_ARCHITECTURE"
}

plan_platform_matches_current() {
  local current_hostname="$1"
  local saved_hostname saved_created saved_kind
  local saved_os_id saved_os_version saved_codename saved_architecture

  saved_hostname="$PLAN_HOSTNAME"
  saved_created="$PLAN_CREATED_AT"
  saved_kind="$PLAN_KIND"
  saved_os_id="$PLAN_OS_ID"
  saved_os_version="$PLAN_OS_VERSION"
  saved_codename="$PLAN_UBUNTU_CODENAME"
  saved_architecture="$PLAN_ARCHITECTURE"
  recovery_reset
  recovery_populate_platform "$current_hostname"
  [[ "$saved_os_id" == "$RECOVERY_OS_ID" \
    && "$saved_os_version" == "$RECOVERY_OS_VERSION" \
    && "$saved_codename" == "$RECOVERY_UBUNTU_CODENAME" \
    && "$saved_architecture" == "$RECOVERY_ARCHITECTURE" ]]
  local status=$?
  PLAN_HOSTNAME="$saved_hostname"
  PLAN_CREATED_AT="$saved_created"
  PLAN_KIND="$saved_kind"
  PLAN_OS_ID="$saved_os_id"
  PLAN_OS_VERSION="$saved_os_version"
  PLAN_UBUNTU_CODENAME="$saved_codename"
  PLAN_ARCHITECTURE="$saved_architecture"
  return "$status"
}

plan_validate_entry() {
  local kind="$1"
  local value="$2"

  case "$kind" in
    software) validate_safe_name "$value" ;;
    apt) validate_apt_package_name "$value" ;;
    flatpak) validate_flatpak_app_spec "$value" ;;
    *) return 1 ;;
  esac
}

plan_validate() {
  local entry option owner line flatpak_scope flatpak_remote flatpak_id flatpak_branch flatpak_target
  local total_bytes=0
  local LC_ALL=C
  local -a scalar_lines=(
    "format=$PLAN_FORMAT"
    "kind=$PLAN_KIND"
    "hostname=$PLAN_HOSTNAME"
    "created_at=$PLAN_CREATED_AT"
    "os_id=$PLAN_OS_ID"
    "os_version=$PLAN_OS_VERSION"
    "ubuntu_codename=$PLAN_UBUNTU_CODENAME"
    "architecture=$PLAN_ARCHITECTURE"
  )
  local -A seen_entries=() seen_options=()
  local -A seen_flatpak_targets=()

  [[ "$PLAN_FORMAT" == '1' ]] || die "Unsupported plan manifest format: $PLAN_FORMAT"
  plan_kind_is_valid "$PLAN_KIND" || die "Invalid plan manifest kind: $PLAN_KIND"
  validate_safe_name "$PLAN_HOSTNAME" || die "Unsafe plan manifest hostname: $PLAN_HOSTNAME"
  [[ "$PLAN_CREATED_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || die "Invalid plan manifest timestamp: $PLAN_CREATED_AT"
  [[ "$PLAN_OS_ID" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
    || die "Unsafe plan manifest os_id: $PLAN_OS_ID"
  [[ "$PLAN_OS_VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._+~-]*$ ]] \
    || die "Unsafe plan manifest os_version: $PLAN_OS_VERSION"
  [[ "$PLAN_UBUNTU_CODENAME" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
    || die "Unsafe plan manifest ubuntu_codename: $PLAN_UBUNTU_CODENAME"
  [[ "$PLAN_ARCHITECTURE" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
    || die "Unsafe plan manifest architecture: $PLAN_ARCHITECTURE"
  (( ${#PLAN_ENTRIES[@]} <= PLAN_MAX_ENTRIES )) \
    || die "Plan manifest exceeds the $PLAN_MAX_ENTRIES-entry limit."
  (( ${#PLAN_OPTIONS[@]} <= PLAN_MAX_OPTIONS )) \
    || die "Plan manifest exceeds the $PLAN_MAX_OPTIONS-option limit."
  (( ${#scalar_lines[@]} + ${#PLAN_ENTRIES[@]} + ${#PLAN_OPTIONS[@]} <= PLAN_MAX_LINES )) \
    || die "Plan manifest exceeds the $PLAN_MAX_LINES-line limit."

  for line in "${scalar_lines[@]}"; do
    (( ${#line} <= PLAN_MAX_LINE_BYTES )) \
      || die "Plan manifest line exceeds $PLAN_MAX_LINE_BYTES bytes."
    ((total_bytes += ${#line} + 1))
  done

  for entry in "${PLAN_ENTRIES[@]}"; do
    plan_validate_entry "$PLAN_KIND" "$entry" \
      || die "Invalid $PLAN_KIND plan entry: $entry"
    [[ -z "${seen_entries[$entry]+set}" ]] \
      || die "Duplicate $PLAN_KIND plan entry: $entry"
    seen_entries["$entry"]=1
    if [[ "$PLAN_KIND" == 'flatpak' ]]; then
      IFS='|' read -r flatpak_scope flatpak_remote flatpak_id flatpak_branch <<< "$entry"
      flatpak_target="$flatpak_scope|$flatpak_id"
      [[ -z "${seen_flatpak_targets[$flatpak_target]+set}" ]] \
        || die "Flatpak plan contains more than one origin or branch for: $flatpak_target"
      seen_flatpak_targets["$flatpak_target"]=1
    fi
    line="entry=$entry"
    (( ${#line} <= PLAN_MAX_LINE_BYTES )) \
      || die "Plan manifest entry line exceeds $PLAN_MAX_LINE_BYTES bytes."
    ((total_bytes += ${#line} + 1))
  done

  if [[ "$PLAN_KIND" != 'software' && ${#PLAN_OPTIONS[@]} -gt 0 ]]; then
    die "Plan kind '$PLAN_KIND' does not support options."
  fi
  for option in "${PLAN_OPTIONS[@]}"; do
    [[ "$option" =~ ^([A-Za-z0-9][A-Za-z0-9._-]*):([A-Za-z0-9][A-Za-z0-9._-]*)$ ]] \
      || die "Invalid software plan option: $option"
    owner="${BASH_REMATCH[1]}"
    [[ -n "${seen_entries[$owner]+set}" ]] \
      || die "Software plan option belongs to an unselected installer: $option"
    [[ -z "${seen_options[$option]+set}" ]] \
      || die "Duplicate software plan option: $option"
    seen_options["$option"]=1
    line="option=$option"
    (( ${#line} <= PLAN_MAX_LINE_BYTES )) \
      || die "Plan manifest option line exceeds $PLAN_MAX_LINE_BYTES bytes."
    ((total_bytes += ${#line} + 1))
  done
  (( total_bytes <= PLAN_MAX_BYTES )) \
    || die "Plan manifest exceeds $PLAN_MAX_BYTES bytes."
}

plan_write_stdout() {
  local entry option

  plan_validate
  printf 'format=%s\n' "$PLAN_FORMAT"
  printf 'kind=%s\n' "$PLAN_KIND"
  printf 'hostname=%s\n' "$PLAN_HOSTNAME"
  printf 'created_at=%s\n' "$PLAN_CREATED_AT"
  printf 'os_id=%s\n' "$PLAN_OS_ID"
  printf 'os_version=%s\n' "$PLAN_OS_VERSION"
  printf 'ubuntu_codename=%s\n' "$PLAN_UBUNTU_CODENAME"
  printf 'architecture=%s\n' "$PLAN_ARCHITECTURE"
  for entry in "${PLAN_ENTRIES[@]}"; do
    printf 'entry=%s\n' "$entry"
  done
  for option in "${PLAN_OPTIONS[@]}"; do
    printf 'option=%s\n' "$option"
  done
}

plan_write_file() {
  local file="$1"
  local directory basename temporary

  directory="${file%/*}"
  [[ "$directory" != "$file" ]] || directory='.'
  basename="${file##*/}"
  [[ -d "$directory" ]] || die "Plan manifest directory does not exist: $directory"
  temporary="$(mktemp "$directory/.${basename}.tmp.XXXXXX")"
  chmod 0600 -- "$temporary"
  if ! plan_write_stdout > "$temporary"; then
    rm -f -- "$temporary"
    die 'Could not write plan manifest.'
  fi
  mv -f -- "$temporary" "$file"
  chmod 0600 -- "$file"
}

plan_read() {
  local file="$1"
  local raw key value byte_count nul_prefix line_number=0
  local -A seen_singletons=()
  local LC_ALL=C

  [[ -f "$file" && ! -L "$file" && -r "$file" ]] \
    || die "Plan manifest does not exist or is not readable: $file"
  byte_count="$(wc -c < "$file")" || die "Could not measure plan manifest: $file"
  byte_count="$(trim "$byte_count")"
  [[ "$byte_count" =~ ^(0|[1-9][0-9]*)$ ]] \
    && (( 10#$byte_count <= PLAN_MAX_BYTES )) \
    || die "$file exceeds the $PLAN_MAX_BYTES-byte plan manifest limit."
  if IFS= read -r -d '' nul_prefix < "$file"; then
    die "$file contains a NUL byte."
  fi
  plan_reset

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    ((line_number += 1))
    (( line_number <= PLAN_MAX_LINES )) || die "$file exceeds the plan line limit."
    (( ${#raw} <= PLAN_MAX_LINE_BYTES )) || die "$file:$line_number exceeds the line limit."
    [[ -n "$raw" && "$raw" == *=* && "$raw" != *$'\r'* ]] \
      || die "$file:$line_number is not a valid key=value line."
    key="${raw%%=*}"
    value="${raw#*=}"
    [[ -n "$key" && -n "$value" && ! "$key" =~ [[:cntrl:]] && ! "$value" =~ [[:cntrl:]] ]] \
      || die "$file:$line_number contains an invalid key or value."
    case "$key" in
      format|kind|hostname|created_at|os_id|os_version|ubuntu_codename|architecture)
        [[ -z "${seen_singletons[$key]+set}" ]] || die "$file:$line_number duplicates '$key'."
        seen_singletons["$key"]=1
        case "$key" in
          format) PLAN_FORMAT="$value" ;;
          kind) PLAN_KIND="$value" ;;
          hostname) PLAN_HOSTNAME="$value" ;;
          created_at) PLAN_CREATED_AT="$value" ;;
          os_id) PLAN_OS_ID="$value" ;;
          os_version) PLAN_OS_VERSION="$value" ;;
          ubuntu_codename) PLAN_UBUNTU_CODENAME="$value" ;;
          architecture) PLAN_ARCHITECTURE="$value" ;;
        esac
        ;;
      entry)
        (( ${#PLAN_ENTRIES[@]} < PLAN_MAX_ENTRIES )) || die "$file exceeds the entry limit."
        PLAN_ENTRIES+=("$value")
        ;;
      option)
        (( ${#PLAN_OPTIONS[@]} < PLAN_MAX_OPTIONS )) || die "$file exceeds the option limit."
        PLAN_OPTIONS+=("$value")
        ;;
      *) die "$file:$line_number contains unknown key '$key'." ;;
    esac
  done < "$file"

  for key in format kind hostname created_at os_id os_version ubuntu_codename architecture; do
    [[ -n "${seen_singletons[$key]+set}" ]] || die "$file is missing required key '$key'."
  done
  plan_validate
}
