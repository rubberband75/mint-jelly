#!/usr/bin/env bash

# Self-contained Git repository artifacts. Git is only run against local source,
# cache, download, and restore paths; snapshot destinations remain inert data.

REPOSITORY_ARTIFACT_FORMAT='1'
REPOSITORY_SYNTHETIC_REF='refs/mint-jelly/snapshot-head'

REPOSITORY_STATE_ID=''
REPOSITORY_STATE_SOURCE=''
REPOSITORY_STATE_OBJECT_FORMAT=''
REPOSITORY_STATE_HEAD_KIND=''
REPOSITORY_STATE_HEAD_REF=''
REPOSITORY_STATE_HEAD_OID=''
REPOSITORY_STATE_REFS=()
REPOSITORY_STATE_SYMREFS=()
REPOSITORY_STATE_STASHES=()
REPOSITORY_STATE_REMOTES=()
REPOSITORY_STATE_REMOTE_URLS=()
REPOSITORY_STATE_REMOTE_PUSHURLS=()
REPOSITORY_STATE_REMOTE_FETCHES=()
REPOSITORY_STATE_BRANCH_REMOTES=()
REPOSITORY_STATE_BRANCH_MERGES=()
REPOSITORY_STATE_INCLUDES=()
REPOSITORY_STATE_EXCLUDES=()

repository_encode_field() {
  printf '%s' "$1" | base64 -w0
}

repository_decode_field() {
  local encoded="$1" output_name="$2" allow_control="${3:-false}" decoded_value sentinel=$'\037'
  local -n output_ref="$output_name"

  [[ "$encoded" =~ ^[A-Za-z0-9+/]*={0,2}$ ]] || return 1
  decoded_value="$(
    status=0
    printf '%s' "$encoded" | base64 --decode 2>/dev/null || status=$?
    printf '%s' "$sentinel"
    exit "$status"
  )" || return 1
  [[ "$decoded_value" == *"$sentinel" ]] || return 1
  decoded_value="${decoded_value%"$sentinel"}"
  [[ "$(repository_encode_field "$decoded_value")" == "$encoded" ]] || return 1
  [[ "$allow_control" == 'true' || ! "$decoded_value" =~ [[:cntrl:]] ]] || return 1
  output_ref="$decoded_value"
}

repository_validate_worktree_path() {
  local path="$1" component
  local -a components=()

  [[ -n "$path" && "$path" != /* ]] || return 1
  IFS='/' read -r -a components <<< "$path"
  for component in "${components[@]}"; do
    [[ -n "$component" && "$component" != '.' && "$component" != '..' \
      && "$component" != '.git' ]] || return 1
  done
}

repository_path_is_within() {
  local child="${1%/}" parent="${2%/}"
  [[ "$child" == "$parent" || "$child" == "$parent/"* ]]
}

repository_paths_overlap() {
  repository_path_is_within "$1" "$2" || repository_path_is_within "$2" "$1"
}

repository_rule_matches() {
  local path="$1" rule
  shift
  for rule in "$@"; do
    [[ "$path" == "$rule" || "$path" == "$rule/"* ]] && return 0
  done
  return 1
}

repository_is_node_modules_path() {
  [[ "/$1/" == */node_modules/* ]]
}

repository_require_no_symlink_parent() {
  local root="$1" relative="$2" current="$root" component component_index
  local -a components=()

  IFS='/' read -r -a components <<< "$relative"
  for ((component_index=0; component_index<${#components[@]}-1; component_index++)); do
    component="${components[$component_index]}"
    current="$current/$component"
    [[ ! -L "$current" ]] \
      || die "Repository selection traverses a symbolic link: $relative"
  done
}

repository_git_path() {
  git -C "$1" rev-parse --path-format=absolute --git-path "$2"
}

repository_source_fingerprint() {
  local root="$1" head_ref head_oid status_hash config_hash

  head_ref="$(git -C "$root" symbolic-ref -q HEAD 2>/dev/null || true)"
  head_oid="$(git -C "$root" rev-parse --verify HEAD 2>/dev/null || true)"
  status_hash="$(git -C "$root" status --porcelain=v2 -z --untracked-files=all | sha256sum)"
  status_hash="${status_hash%% *}"
  config_hash="$(git -C "$root" config --local --null --list | sha256sum)"
  config_hash="${config_hash%% *}"
  {
    printf 'head_ref=%s\nhead_oid=%s\nstatus=%s\nconfig=%s\n' \
      "$head_ref" "$head_oid" "$status_hash" "$config_hash"
    git -C "$root" for-each-ref --format='%(refname) %(objectname)' | LC_ALL=C sort
  } | sha256sum | sed 's/[[:space:]].*$//'
}

repository_preflight_source() {
  local id="$1" root="$2" resolved_root top git_dir common_dir marker path attr value

  validate_safe_name "$id" || die "Invalid repository identity: $id"
  [[ -d "$root" && ! -L "$root" ]] || die "Repository path is missing or unsafe: $root"
  resolved_root="$(realpath -e -- "$root")" || die "Could not resolve repository path: $root"
  top="$(git -C "$resolved_root" rev-parse --show-toplevel 2>/dev/null)" \
    || die "Path is not a Git worktree: $root"
  top="$(realpath -e -- "$top")" || die "Could not resolve Git worktree root: $top"
  [[ "$resolved_root" == "$top" ]] || die "Configured path is not the Git worktree root: $root"
  [[ "$(git -C "$root" rev-parse --is-bare-repository)" == 'false' ]] \
    || die "Bare repositories cannot be configured as worktrees: $root"

  git_dir="$(git -C "$root" rev-parse --absolute-git-dir)"
  common_dir="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)"
  git_dir="$(realpath -e -- "$git_dir")"
  common_dir="$(realpath -e -- "$common_dir")"
  [[ "$git_dir" == "$common_dir" ]] \
    || die "Linked Git worktrees are not yet supported: $root"
  [[ "$(git -C "$root" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]] \
    || die "Repositories with additional or stale linked worktrees are not yet supported: $root"
  [[ "$(git -C "$root" rev-parse --is-shallow-repository)" == 'false' ]] \
    || die "Shallow repositories must be fully hydrated before backup: $root"
  [[ "$(git -C "$root" config --bool --get core.sparseCheckout 2>/dev/null || printf false)" != 'true' ]] \
    || die "Sparse worktrees are not yet supported: $root"
  [[ -z "$(git -C "$root" config --get extensions.partialClone 2>/dev/null || true)" ]] \
    || die "Partial-clone repositories must be fully hydrated before backup: $root"
  if git -C "$root" config --get-regexp '^remote\..*\.promisor$' 2>/dev/null \
    | awk '$2 == "true" { found=1 } END { exit !found }'; then
    die "Partial-clone repositories must be fully hydrated before backup: $root"
  fi

  for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG rebase-apply rebase-merge; do
    path="$(repository_git_path "$root" "$marker")"
    [[ ! -e "$path" && ! -L "$path" ]] \
      || die "Repository has an in-progress Git operation ($marker): $root"
  done
  [[ -z "$(git -C "$root" ls-files --unmerged)" ]] \
    || die "Repository has unresolved index entries: $root"
  [[ -z "$(git -C "$root" ls-files --stage | awk '$1 == "160000" { print; exit }')" ]] \
    || die "Repositories containing submodules are not yet supported: $root"
  [[ -z "$(git -C "$root" for-each-ref --format='%(refname)' refs/mint-jelly/)" ]] \
    || die "Repository uses Mint Jelly's reserved ref namespace: $root"

  while IFS= read -r -d '' path \
    && IFS= read -r -d '' attr \
    && IFS= read -r -d '' value; do
    [[ "$value" != 'lfs' ]] \
      || die "Git LFS repositories require LFS-object backup support before capture: $root"
  done < <(git -C "$root" ls-files -z \
    | git -C "$root" check-attr --stdin -z filter)

  repository_preflight_history "$root"
}

repository_preflight_history() {
  local root="$1" oid type size
  local -a revisions=(--all)
  local -a stash_oids=()

  if git -C "$root" rev-parse --verify HEAD >/dev/null 2>&1; then
    revisions+=(HEAD)
  fi
  mapfile -t stash_oids < <(git -C "$root" reflog show --format='%H' refs/stash 2>/dev/null || true)
  revisions+=("${stash_oids[@]}")

  while read -r oid type size; do
    case "$type" in
      tree)
        if git -C "$root" cat-file -p "$oid" | grep '^160000 commit ' >/dev/null; then
          die "Repository history contains a submodule gitlink: $root"
        fi
        ;;
      blob)
        if (( size <= 1024 )) && git -C "$root" cat-file blob "$oid" | awk '
          NR == 1 { version = ($0 == "version https://git-lfs.github.com/spec/v1") }
          NR == 2 { object = ($0 ~ /^oid sha256:[0-9a-f]{64}$/) }
          NR == 3 { size = ($0 ~ /^size [0-9]+$/) }
          END { exit !(version && object && size) }
        '; then
          die "Repository history contains Git LFS pointer data that is not self-contained: $root"
        fi
        ;;
    esac
  done < <(
    git -C "$root" rev-list --objects "${revisions[@]}" \
      | awk '{ print $1 }' | LC_ALL=C sort -u \
      | git -C "$root" cat-file --batch-check='%(objectname) %(objecttype) %(objectsize)'
  )
}

repository_add_inventory_path() {
  local root="$1" relative="$2" output="$3" absolute

  repository_validate_worktree_path "$relative" \
    || die "Git reported an unsafe worktree path."
  absolute="$root/$relative"
  [[ -f "$absolute" || -L "$absolute" ]] || {
    [[ ! -e "$absolute" ]] && return 0
    die "Unsupported selected repository path type: $relative"
  }
  printf '%s\0' "$relative" >> "$output"
}

repository_build_file_list() {
  local root="$1" output="$2" includes_name="$3" excludes_name="$4"
  local -n includes_ref="$includes_name"
  local -n excludes_ref="$excludes_name"
  local raw relative include absolute found unsupported

  raw="$(mktemp "${output}.raw.XXXXXX")"
  : > "$raw"
  while IFS= read -r -d '' relative; do
    [[ -e "$root/$relative" || -L "$root/$relative" ]] || continue
    repository_add_inventory_path "$root" "$relative" "$raw"
  done < <(git -C "$root" ls-files --cached -z)

  while IFS= read -r -d '' relative; do
    repository_is_node_modules_path "$relative" && continue
    repository_rule_matches "$relative" "${excludes_ref[@]}" && continue
    repository_add_inventory_path "$root" "$relative" "$raw"
  done < <(git -C "$root" ls-files --others --exclude-standard -z)

  for include in "${includes_ref[@]}"; do
    validate_repository_relative_path "$include" \
      || die "Unsafe explicit repository include: $include"
    repository_require_no_symlink_parent "$root" "$include"
    absolute="$root/$include"
    [[ -e "$absolute" || -L "$absolute" ]] \
      || die "Required repository include does not exist: $include"
    if [[ -d "$absolute" && ! -L "$absolute" ]]; then
      unsupported="$(find -P "$absolute" -name .git -prune -o \
        ! -type d ! -type f ! -type l -print -quit)"
      [[ -z "$unsupported" ]] \
        || die "Explicit repository include contains an unsupported file type: $unsupported"
      while IFS= read -r -d '' found; do
        relative="${found#"$root/"}"
        repository_add_inventory_path "$root" "$relative" "$raw"
      done < <(find -P "$absolute" -name .git -prune -o \( -type f -o -type l \) -print0)
    else
      repository_add_inventory_path "$root" "$include" "$raw"
    fi
  done
  LC_ALL=C sort -zu -- "$raw" > "$output"
  rm -f -- "$raw"
}

repository_inventory_from_list() {
  local root="$1" list="$2" output="$3" relative absolute kind mode digest target

  : > "$output"
  while IFS= read -r -d '' relative; do
    repository_validate_worktree_path "$relative" \
      || die 'Repository file inventory contains an unsafe path.'
    absolute="$root/$relative"
    if [[ -L "$absolute" ]]; then
      kind='link'
      target="$(readlink -- "$absolute"; printf '\037')"
      target="${target%$'\037'}"
      digest="$(printf '%s' "$target" | sha256sum)"
    elif [[ -f "$absolute" ]]; then
      kind='file'
      digest="$(sha256sum -- "$absolute")"
    else
      die "Selected repository file disappeared during capture: $relative"
    fi
    digest="${digest%% *}"
    mode="$(stat -c '%a' -- "$absolute")"
    printf '%s|%s|%s|%s\n' "$(repository_encode_field "$relative")" \
      "$kind" "$mode" "$digest" >> "$output"
  done < "$list"
}

repository_build_complete_tree_list() {
  local root="$1" output="$2" allow_root_git="${3:-false}" found relative

  if [[ "$allow_root_git" == true ]]; then
    [[ -d "$root/.git" && ! -L "$root/.git" ]] \
      || die 'Restored repository is missing its Git administration directory.'
  else
    [[ ! -e "$root/.git" && ! -L "$root/.git" ]] \
      || die 'Repository worktree artifact contains a forbidden .git entry.'
  fi
  [[ -z "$(find -P "$root" -mindepth 1 -name .git ! -path "$root/.git" -print -quit)" ]] \
    || die 'Repository worktree artifact contains a nested .git entry.'
  [[ -z "$(find -P "$root" -path "$root/.git" -prune -o \
    -mindepth 1 ! -type d ! -type f ! -type l -print -quit)" ]] \
    || die 'Repository worktree artifact contains an unsupported file type.'
  [[ -z "$(find -P "$root" -path "$root/.git" -prune -o \
    -mindepth 1 -type d -empty -print -quit)" ]] \
    || die 'Repository worktree artifact contains an unexpected empty directory.'
  : > "$output"
  while IFS= read -r -d '' found; do
    relative="${found#"$root/"}"
    repository_validate_worktree_path "$relative" \
      || die "Restored worktree contains an unsafe path: $relative"
    printf '%s\0' "$relative" >> "$output"
  done < <(find -P "$root" -path "$root/.git" -prune -o \
    -mindepth 1 \( -type f -o -type l \) -print0)
  LC_ALL=C sort -zu -o "$output" "$output"
}

repository_create_empty_template() {
  mktemp -d "${TMPDIR:-/tmp}/mint-jelly-git-template.XXXXXX"
}

repository_sanitize_mirror() {
  local mirror="$1"

  rm -rf -- "$mirror/hooks" "$mirror/logs"
  mkdir -p -- "$mirror/hooks"
  rm -f -- "$mirror/objects/info/alternates" "$mirror/FETCH_HEAD" \
    "$mirror/ORIG_HEAD" "$mirror/MERGE_HEAD"
  git --git-dir="$mirror" config --local core.bare true
  git --git-dir="$mirror" config --local core.logAllRefUpdates false
  git --git-dir="$mirror" config --local gc.auto 0
  git --git-dir="$mirror" config --local maintenance.auto false
  while IFS= read -r key; do
    case "$key" in
      core.repositoryformatversion|core.filemode|core.bare|core.logallrefupdates|gc.auto|maintenance.auto|extensions.objectformat) ;;
      *) git --git-dir="$mirror" config --local --unset-all "$key" || true ;;
    esac
  done < <(git --git-dir="$mirror" config --local --name-only --list)
}

repository_mirror_delete_refs() {
  local mirror="$1" ref
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    git --git-dir="$mirror" update-ref --no-deref -d "$ref"
  done < <(git --git-dir="$mirror" for-each-ref --format='%(refname)')
}

repository_cache_mirror_is_safe() {
  local mirror="$1" key keys
  local -A seen=()

  [[ -d "$mirror" && ! -L "$mirror" \
    && -f "$mirror/config" && ! -L "$mirror/config" \
    && -f "$mirror/HEAD" && ! -L "$mirror/HEAD" ]] || return 1
  [[ -z "$(find -P "$mirror" -mindepth 1 ! -type d ! -type f -print -quit)" ]] || return 1
  keys="$(git config --file "$mirror/config" --no-includes --name-only --list 2>/dev/null)" || return 1
  while IFS= read -r key; do
    [[ -z "${seen[$key]+set}" ]] || return 1
    seen["$key"]=1
    case "$key" in
      core.repositoryformatversion|core.filemode|core.bare|core.logallrefupdates|gc.auto|maintenance.auto|extensions.objectformat) ;;
      *) return 1 ;;
    esac
  done <<< "$keys"
  [[ "$(git config --file "$mirror/config" --no-includes --bool --get core.bare 2>/dev/null || true)" == true ]]
}

repository_fsck_mirror() {
  local mirror="$1" output

  output="$(git --git-dir="$mirror" fsck --full --strict --no-reflogs 2>&1)" \
    || die 'Repository mirror failed Git object validation.'
  if grep -E '^(dangling|unreachable) ' <<< "$output" >/dev/null; then
    die 'Repository mirror contains objects that are not retained by captured refs.'
  fi
}

repository_mirror_needs_prune() {
  local mirror="$1" output

  output="$(git --git-dir="$mirror" fsck --full --strict --no-reflogs 2>&1)" \
    || die 'Repository mirror failed Git object validation.'
  grep -E '^(dangling|unreachable) ' <<< "$output" >/dev/null
}

repository_update_mirror() {
  local id="$1" root="$2" cache_root="$3" mirror object_format existing_format template head_oid head_ref
  local ref target oid stash_ref index=0
  local -a stash_oids=()

  [[ ! -L "$cache_root" && ( ! -e "$cache_root" || -d "$cache_root" ) ]] \
    || die "Unsafe repository cache root: $cache_root"
  mkdir -p -- "$cache_root"
  chmod 0700 -- "$cache_root"
  mirror="$cache_root/$id.git"
  object_format="$(git -C "$root" rev-parse --show-object-format)"
  [[ "$object_format" == 'sha1' || "$object_format" == 'sha256' ]] \
    || die "Unsupported Git object format: $object_format"
  if [[ -e "$mirror" || -L "$mirror" ]]; then
    if repository_cache_mirror_is_safe "$mirror"; then
      existing_format="$(git --git-dir="$mirror" rev-parse --show-object-format 2>/dev/null || true)"
      [[ "$existing_format" == "$object_format" ]] || rm -rf -- "$mirror"
    else
      rm -rf -- "$mirror"
    fi
  fi
  if [[ ! -d "$mirror" ]]; then
    template="$(repository_create_empty_template)"
    git init --quiet --bare --template="$template" --object-format="$object_format" "$mirror"
    rm -rf -- "$template"
  fi
  repository_sanitize_mirror "$mirror"
  repository_mirror_delete_refs "$mirror"
  if [[ -n "$(git -C "$root" for-each-ref --format='%(refname)' | sed -n '1p')" ]]; then
    git --git-dir="$mirror" -c gc.auto=0 -c maintenance.auto=false \
      -c protocol.file.allow=always fetch --quiet --force --no-tags --no-write-fetch-head \
      "$root" '+refs/*:refs/*'
  fi
  while IFS=$'\t' read -r ref target; do
    [[ -n "$target" ]] || continue
    git --git-dir="$mirror" symbolic-ref "$ref" "$target"
  done < <(git -C "$root" for-each-ref --format='%(refname)%09%(symref)')

  mapfile -t stash_oids < <(git -C "$root" reflog show --format='%H' refs/stash 2>/dev/null || true)
  for oid in "${stash_oids[@]}"; do
    printf -v stash_ref 'refs/mint-jelly/stashes/%08d' "$index"
    git --git-dir="$mirror" -c gc.auto=0 -c maintenance.auto=false \
      -c protocol.file.allow=always fetch --quiet --force --no-tags --no-write-fetch-head \
      "$root" "+$oid:$stash_ref"
    ((index += 1))
  done
  head_oid="$(git -C "$root" rev-parse --verify HEAD 2>/dev/null || true)"
  head_ref="$(git -C "$root" symbolic-ref -q HEAD 2>/dev/null || true)"
  if [[ -n "$head_oid" ]]; then
    git --git-dir="$mirror" -c gc.auto=0 -c maintenance.auto=false \
      -c protocol.file.allow=always fetch --quiet --force --no-tags --no-write-fetch-head \
      "$root" "+HEAD:$REPOSITORY_SYNTHETIC_REF"
  fi
  if [[ -n "$head_ref" ]]; then
    git --git-dir="$mirror" symbolic-ref HEAD "$head_ref"
  elif [[ -n "$head_oid" ]]; then
    git --git-dir="$mirror" update-ref --no-deref HEAD "$head_oid"
  fi
  repository_sanitize_mirror "$mirror"
  if repository_mirror_needs_prune "$mirror"; then
    git --git-dir="$mirror" reflog expire --expire=now --all
    git --git-dir="$mirror" gc --prune=now --quiet
  fi
  repository_sanitize_mirror "$mirror"
  repository_fsck_mirror "$mirror"
  printf '%s' "$mirror"
}

repository_url_is_credential_bearing() {
  [[ "$1" =~ ^https?://[^/]+@ ]]
}

repository_validate_remote_url() {
  local value="$1"

  [[ -n "$value" && ! "$value" =~ [[:cntrl:]] ]] || return 1
  repository_url_is_credential_bearing "$value" && return 1
  case "$value" in
    /*) validate_absolute_path "$value" ;;
    http://*|https://*|ssh://*|git://*|file://*|ftp://*|ftps://*)
      [[ "$value" != *[[:space:]]* ]]
      ;;
    *)
      [[ "$value" =~ ^([^/@:[:space:]]+@)?(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9._-]+):[^[:space:]]+$ ]]
      ;;
  esac
}

repository_write_state() {
  local id="$1" root="$2" output="$3" inventory="$4" includes_name="$5" excludes_name="$6"
  local -n includes_ref="$includes_name"
  local -n excludes_ref="$excludes_name"
  local head_ref head_oid head_kind object_format ref oid remote value branch target record message
  local ref_count=0 symref_count=0 stash_count=0 remote_count=0 worktree_count include exclude

  head_ref="$(git -C "$root" symbolic-ref -q HEAD 2>/dev/null || true)"
  head_oid="$(git -C "$root" rev-parse --verify HEAD 2>/dev/null || true)"
  if [[ -n "$head_ref" && -n "$head_oid" ]]; then head_kind='symbolic'
  elif [[ -n "$head_ref" ]]; then head_kind='unborn'
  else head_kind='detached'
  fi
  object_format="$(git -C "$root" rev-parse --show-object-format)"
  worktree_count="$(wc -l < "$inventory")"
  {
    printf 'version=%s\n' "$REPOSITORY_ARTIFACT_FORMAT"
    printf 'id=%s\n' "$id"
    printf 'source=%s\n' "$(repository_encode_field "$root")"
    printf 'object_format=%s\n' "$object_format"
    printf 'head_kind=%s\n' "$head_kind"
    [[ -z "$head_ref" ]] || printf 'head_ref=%s\n' "$(repository_encode_field "$head_ref")"
    [[ -z "$head_oid" ]] || printf 'head_oid=%s\n' "$head_oid"
    while read -r oid ref; do
      [[ -n "$ref" ]] || continue
      printf 'ref=%s|%s\n' "$(repository_encode_field "$ref")" "$oid"
      ((ref_count += 1))
    done < <(git -C "$root" for-each-ref --format='%(objectname) %(refname)' | LC_ALL=C sort -k2)
    while IFS=$'\t' read -r ref target; do
      [[ -n "$target" ]] || continue
      printf 'symref=%s|%s\n' \
        "$(repository_encode_field "$ref")" "$(repository_encode_field "$target")"
      ((symref_count += 1))
    done < <(git -C "$root" for-each-ref --format='%(refname)%09%(symref)' | LC_ALL=C sort)
    while IFS= read -r record; do
      [[ "$record" == *$'\t'* ]] || die 'Could not encode a stash reflog entry.'
      oid="${record%%$'\t'*}"
      message="${record#*$'\t'}"
      printf 'stash=%s|%s\n' "$oid" "$(repository_encode_field "$message")"
      ((stash_count += 1))
    done < <(git -C "$root" reflog show --format='%H%x09%gs' refs/stash 2>/dev/null || true)
    while IFS= read -r remote; do
      [[ -n "$remote" ]] || continue
      validate_safe_name "$remote" || die "Unsupported Git remote name: $remote"
      printf 'remote=%s\n' "$(repository_encode_field "$remote")"
      ((remote_count += 1))
      while IFS= read -r -d '' value; do
        repository_validate_remote_url "$value" \
          || die "Git remote '$remote' has an unsafe or non-portable URL: $value"
        printf 'remote_url=%s|%s\n' "$(repository_encode_field "$remote")" "$(repository_encode_field "$value")"
      done < <(git -C "$root" config --null --get-all "remote.$remote.url" 2>/dev/null || true)
      while IFS= read -r -d '' value; do
        repository_validate_remote_url "$value" \
          || die "Git remote '$remote' has an unsafe or non-portable push URL: $value"
        printf 'remote_pushurl=%s|%s\n' "$(repository_encode_field "$remote")" "$(repository_encode_field "$value")"
      done < <(git -C "$root" config --null --get-all "remote.$remote.pushurl" 2>/dev/null || true)
      while IFS= read -r -d '' value; do
        [[ ! "$value" =~ [[:cntrl:]] ]] || die "Git remote '$remote' refspec contains a control character."
        printf 'remote_fetch=%s|%s\n' "$(repository_encode_field "$remote")" "$(repository_encode_field "$value")"
      done < <(git -C "$root" config --null --get-all "remote.$remote.fetch" 2>/dev/null || true)
    done < <(git -C "$root" remote)
    while IFS= read -r branch; do
      [[ -n "$branch" ]] || continue
      value="$(git -C "$root" config --get "branch.$branch.remote" 2>/dev/null || true)"
      [[ -z "$value" ]] || printf 'branch_remote=%s|%s\n' \
        "$(repository_encode_field "$branch")" "$(repository_encode_field "$value")"
      while IFS= read -r -d '' value; do
        printf 'branch_merge=%s|%s\n' "$(repository_encode_field "$branch")" "$(repository_encode_field "$value")"
      done < <(git -C "$root" config --null --get-all "branch.$branch.merge" 2>/dev/null || true)
    done < <(git -C "$root" for-each-ref --format='%(refname:strip=2)' refs/heads/ | LC_ALL=C sort)
    for include in "${includes_ref[@]}"; do
      printf 'include=%s\n' "$(repository_encode_field "$include")"
    done
    for exclude in "${excludes_ref[@]}"; do
      printf 'exclude=%s\n' "$(repository_encode_field "$exclude")"
    done
    printf 'ref_count=%d\n' "$ref_count"
    printf 'symref_count=%d\n' "$symref_count"
    printf 'stash_count=%d\n' "$stash_count"
    printf 'remote_count=%d\n' "$remote_count"
    printf 'worktree_count=%s\n' "$worktree_count"
  } > "$output"
}

repository_write_checksums() {
  local artifact="$1"
  (
    cd -- "$artifact"
    sha256sum -- state.manifest worktree.inventory > checksums.manifest
  )
}

repository_capture_artifact() {
  local id="$1" root="$2" artifact="$3" cache_root="$4" includes_name="$5" excludes_name="$6"
  local mirror file_list second_list source_inventory start_fingerprint end_fingerprint template
  local -n includes_ref="$includes_name"
  local -n excludes_ref="$excludes_name"

  require_cmd base64
  require_cmd git
  require_cmd realpath
  require_cmd rsync
  require_cmd sha256sum
  require_cmd sort
  require_cmd stat
  repository_preflight_source "$id" "$root"
  root="$(realpath -e -- "$root")"
  repository_paths_overlap "$(realpath -m -- "$artifact")" "$root" \
    && die "Repository artifact staging directory overlaps its source: $root"
  repository_paths_overlap "$(realpath -m -- "$cache_root")" "$root" \
    && die "Repository cache directory overlaps its source: $root"
  [[ ! -e "$artifact" && ! -L "$artifact" ]] || die "Repository artifact path already exists: $artifact"
  mkdir -p -- "$artifact/worktree" "$artifact/repository.git"
  chmod 0700 -- "$artifact" "$artifact/worktree" "$artifact/repository.git"
  file_list="$artifact/.capture-files"
  second_list="$artifact/.capture-files.after"
  source_inventory="$artifact/.source.inventory"

  start_fingerprint="$(repository_source_fingerprint "$root")"
  mirror="$(repository_update_mirror "$id" "$root" "$cache_root")"
  rsync --archive --delete -- "$mirror/" "$artifact/repository.git/"
  repository_build_file_list "$root" "$file_list" "$includes_name" "$excludes_name"
  rsync --archive --from0 --files-from="$file_list" -- "$root/" "$artifact/worktree/"
  repository_inventory_from_list "$artifact/worktree" "$file_list" "$artifact/worktree.inventory"
  repository_inventory_from_list "$root" "$file_list" "$source_inventory"
  cmp -s -- "$artifact/worktree.inventory" "$source_inventory" \
    || die "Repository files changed while '$id' was being captured."
  repository_build_file_list "$root" "$second_list" "$includes_name" "$excludes_name"
  cmp -s -- "$file_list" "$second_list" \
    || die "Repository file selection changed while '$id' was being captured."
  repository_write_state "$id" "$root" "$artifact/state.manifest" \
    "$artifact/worktree.inventory" "$includes_name" "$excludes_name"
  end_fingerprint="$(repository_source_fingerprint "$root")"
  [[ "$start_fingerprint" == "$end_fingerprint" ]] \
    || die "Repository state changed while '$id' was being captured; retry the backup."
  rm -f -- "$file_list" "$second_list" "$source_inventory"
  repository_write_checksums "$artifact"
}

repository_state_reset() {
  REPOSITORY_STATE_ID=''
  REPOSITORY_STATE_SOURCE=''
  REPOSITORY_STATE_OBJECT_FORMAT=''
  REPOSITORY_STATE_HEAD_KIND=''
  REPOSITORY_STATE_HEAD_REF=''
  REPOSITORY_STATE_HEAD_OID=''
  REPOSITORY_STATE_REFS=()
  REPOSITORY_STATE_SYMREFS=()
  REPOSITORY_STATE_STASHES=()
  REPOSITORY_STATE_REMOTES=()
  REPOSITORY_STATE_REMOTE_URLS=()
  REPOSITORY_STATE_REMOTE_PUSHURLS=()
  REPOSITORY_STATE_REMOTE_FETCHES=()
  REPOSITORY_STATE_BRANCH_REMOTES=()
  REPOSITORY_STATE_BRANCH_MERGES=()
  REPOSITORY_STATE_INCLUDES=()
  REPOSITORY_STATE_EXCLUDES=()
}

repository_state_parse() {
  local manifest="$1" inventory
  local raw key value left right decoded_left decoded_right entry name path other
  local version='' declared_refs='' declared_symrefs='' declared_stashes=''
  local declared_remotes='' declared_files='' actual_refs=0 actual_symrefs=0
  local actual_stashes=0 actual_remotes=0 actual_files
  local expected_oid_length
  local -A single=() seen_refs=() seen_symrefs=() seen_remotes=()
  local -A seen_includes=() seen_excludes=() seen_branch_remotes=()

  inventory="${2-${manifest%/*}/worktree.inventory}"

  repository_state_reset
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    [[ "$raw" == *=* ]] || die 'Repository state manifest contains an invalid line.'
    key="${raw%%=*}"; value="${raw#*=}"
    case "$key" in
      version|id|source|object_format|head_kind|head_ref|head_oid|ref_count|symref_count|stash_count|remote_count|worktree_count)
        [[ -z "${single[$key]+set}" ]] || die "Repository state repeats '$key'."
        single["$key"]=1
        case "$key" in
          version) version="$value" ;;
          id) REPOSITORY_STATE_ID="$value" ;;
          source) repository_decode_field "$value" REPOSITORY_STATE_SOURCE || die 'Repository state has an invalid source path.' ;;
          object_format) REPOSITORY_STATE_OBJECT_FORMAT="$value" ;;
          head_kind) REPOSITORY_STATE_HEAD_KIND="$value" ;;
          head_ref) repository_decode_field "$value" REPOSITORY_STATE_HEAD_REF || die 'Repository state has an invalid HEAD ref.' ;;
          head_oid) REPOSITORY_STATE_HEAD_OID="$value" ;;
          ref_count) declared_refs="$value" ;;
          symref_count) declared_symrefs="$value" ;;
          stash_count) declared_stashes="$value" ;;
          remote_count) declared_remotes="$value" ;;
          worktree_count) declared_files="$value" ;;
        esac
        ;;
      remote|include|exclude)
        repository_decode_field "$value" decoded_left \
          || die "Repository state has an invalid encoded '$key' value."
        case "$key" in
          remote) REPOSITORY_STATE_REMOTES+=("$value"); ((actual_remotes += 1)) ;;
          include) REPOSITORY_STATE_INCLUDES+=("$value") ;;
          exclude) REPOSITORY_STATE_EXCLUDES+=("$value") ;;
        esac
        ;;
      ref|symref|stash|remote_url|remote_pushurl|remote_fetch|branch_remote|branch_merge)
        [[ "$value" == *'|'* ]] || die "Repository state has an invalid '$key' entry."
        left="${value%%|*}"; right="${value#*|}"
        if [[ "$key" == stash ]]; then
          decoded_left="$left"
          repository_decode_field "$right" decoded_right \
            || die "Repository state has an invalid encoded '$key' value."
        else
          repository_decode_field "$left" decoded_left \
            || die "Repository state has an invalid encoded '$key' identity."
          if [[ "$key" == ref ]]; then
            decoded_right="$right"
          else
            repository_decode_field "$right" decoded_right \
              || die "Repository state has an invalid encoded '$key' value."
          fi
        fi
        case "$key" in
          ref) REPOSITORY_STATE_REFS+=("$left|$decoded_right"); ((actual_refs += 1)) ;;
          symref) REPOSITORY_STATE_SYMREFS+=("$left|$right"); ((actual_symrefs += 1)) ;;
          stash) REPOSITORY_STATE_STASHES+=("$left|$right"); ((actual_stashes += 1)) ;;
          remote_url) REPOSITORY_STATE_REMOTE_URLS+=("$left|$right") ;;
          remote_pushurl) REPOSITORY_STATE_REMOTE_PUSHURLS+=("$left|$right") ;;
          remote_fetch) REPOSITORY_STATE_REMOTE_FETCHES+=("$left|$right") ;;
          branch_remote) REPOSITORY_STATE_BRANCH_REMOTES+=("$left|$right") ;;
          branch_merge) REPOSITORY_STATE_BRANCH_MERGES+=("$left|$right") ;;
        esac
        ;;
      *) die "Repository state contains unknown key '$key'." ;;
    esac
  done < "$manifest"
  [[ "$version" == "$REPOSITORY_ARTIFACT_FORMAT" ]] || die 'Unsupported repository artifact format.'
  validate_safe_name "$REPOSITORY_STATE_ID" || die 'Repository state has an unsafe identity.'
  validate_absolute_path "$REPOSITORY_STATE_SOURCE" || die 'Repository state has an unsafe source path.'
  [[ "$REPOSITORY_STATE_OBJECT_FORMAT" == sha1 || "$REPOSITORY_STATE_OBJECT_FORMAT" == sha256 ]] \
    || die 'Repository state has an unsupported object format.'
  expected_oid_length=40
  [[ "$REPOSITORY_STATE_OBJECT_FORMAT" != sha256 ]] || expected_oid_length=64
  [[ "$REPOSITORY_STATE_HEAD_KIND" == symbolic || "$REPOSITORY_STATE_HEAD_KIND" == detached \
    || "$REPOSITORY_STATE_HEAD_KIND" == unborn ]] || die 'Repository state has an invalid HEAD kind.'
  if [[ "$REPOSITORY_STATE_HEAD_KIND" == symbolic || "$REPOSITORY_STATE_HEAD_KIND" == unborn ]]; then
    git check-ref-format "$REPOSITORY_STATE_HEAD_REF" >/dev/null \
      || die 'Repository state has an invalid symbolic HEAD.'
  else
    [[ -z "$REPOSITORY_STATE_HEAD_REF" ]] || die 'Detached repository state unexpectedly contains a HEAD ref.'
  fi
  if [[ "$REPOSITORY_STATE_HEAD_KIND" == unborn ]]; then
    [[ -z "$REPOSITORY_STATE_HEAD_OID" ]] || die 'Unborn repository state unexpectedly contains a HEAD object.'
  else
    [[ "$REPOSITORY_STATE_HEAD_OID" =~ ^[0-9a-f]+$ \
      && ${#REPOSITORY_STATE_HEAD_OID} -eq expected_oid_length ]] \
      || die 'Repository state has an invalid HEAD object.'
  fi
  [[ "$declared_refs" =~ ^(0|[1-9][0-9]*)$ && "$declared_refs" -eq "$actual_refs" ]] \
    || die 'Repository state ref count does not match.'
  [[ "$declared_symrefs" =~ ^(0|[1-9][0-9]*)$ && "$declared_symrefs" -eq "$actual_symrefs" ]] \
    || die 'Repository state symbolic-ref count does not match.'
  [[ "$declared_stashes" =~ ^(0|[1-9][0-9]*)$ && "$declared_stashes" -eq "$actual_stashes" ]] \
    || die 'Repository state stash count does not match.'
  [[ "$declared_remotes" =~ ^(0|[1-9][0-9]*)$ && "$declared_remotes" -eq "$actual_remotes" ]] \
    || die 'Repository state remote count does not match.'
  [[ "$declared_files" =~ ^(0|[1-9][0-9]*)$ ]] \
    || die 'Repository state has an invalid worktree count.'
  if [[ -n "$inventory" ]]; then
    [[ -f "$inventory" && ! -L "$inventory" ]] || die 'Repository state is missing its worktree inventory.'
    actual_files="$(wc -l < "$inventory")"
    [[ "$declared_files" -eq "$actual_files" ]] \
      || die 'Repository state worktree count does not match.'
  fi

  for entry in "${REPOSITORY_STATE_REFS[@]}"; do
    repository_decode_field "${entry%%|*}" name || die 'Repository state has an invalid ref name.'
    git check-ref-format "$name" >/dev/null || die "Repository state has an unsafe ref: $name"
    [[ "$name" != refs/mint-jelly/* ]] || die 'Repository state uses the reserved ref namespace.'
    value="${entry#*|}"
    [[ "$value" =~ ^[0-9a-f]+$ && ${#value} -eq expected_oid_length ]] \
      || die "Repository state has an invalid ref object: $name"
    [[ -z "${seen_refs[$name]+set}" ]] || die "Repository state repeats ref: $name"
    seen_refs["$name"]="$value"
  done
  for entry in "${REPOSITORY_STATE_SYMREFS[@]}"; do
    repository_decode_field "${entry%%|*}" name || die 'Repository state has an invalid symbolic ref name.'
    repository_decode_field "${entry#*|}" value || die "Repository state has an invalid symbolic ref target: $name"
    git check-ref-format "$name" >/dev/null && git check-ref-format "$value" >/dev/null \
      || die "Repository state has an unsafe symbolic ref: $name"
    [[ -n "${seen_refs[$name]+set}" && -n "${seen_refs[$value]+set}" ]] \
      || die "Repository symbolic ref '$name' has an unknown target."
    [[ -z "${seen_symrefs[$name]+set}" ]] || die "Repository state repeats symbolic ref: $name"
    seen_symrefs["$name"]=1
  done
  for entry in "${REPOSITORY_STATE_STASHES[@]}"; do
    value="${entry%%|*}"
    [[ "$value" =~ ^[0-9a-f]+$ && ${#value} -eq expected_oid_length ]] \
      || die 'Repository state has an invalid stash object.'
  done
  if (( ${#REPOSITORY_STATE_STASHES[@]} > 0 )); then
    [[ -n "${seen_refs[refs/stash]+set}" \
      && "${REPOSITORY_STATE_STASHES[0]%%|*}" == "${seen_refs[refs/stash]}" ]] \
      || die 'Repository stash reflog does not match refs/stash.'
  fi
  for entry in "${REPOSITORY_STATE_REMOTES[@]}"; do
    repository_decode_field "$entry" name || die 'Repository state has an invalid remote name.'
    validate_safe_name "$name" || die "Repository state has an unsafe remote name: $name"
    [[ -z "${seen_remotes[$name]+set}" ]] || die "Repository state repeats remote: $name"
    seen_remotes["$name"]=1
  done
  for entry in "${REPOSITORY_STATE_REMOTE_URLS[@]}" "${REPOSITORY_STATE_REMOTE_PUSHURLS[@]}" \
    "${REPOSITORY_STATE_REMOTE_FETCHES[@]}"; do
    repository_decode_field "${entry%%|*}" name || die 'Repository state has an invalid remote metadata name.'
    repository_decode_field "${entry#*|}" value || die "Repository state has invalid metadata for remote '$name'."
    [[ -n "${seen_remotes[$name]+set}" ]] || die "Repository metadata references unknown remote '$name'."
  done
  for entry in "${REPOSITORY_STATE_REMOTE_URLS[@]}" "${REPOSITORY_STATE_REMOTE_PUSHURLS[@]}"; do
    repository_decode_field "${entry#*|}" value || die 'Repository state has an invalid remote URL.'
    repository_validate_remote_url "$value" || die "Repository state has an unsafe remote URL: $value"
  done
  for entry in "${REPOSITORY_STATE_BRANCH_REMOTES[@]}"; do
    repository_decode_field "${entry%%|*}" name || die 'Repository state has an invalid branch name.'
    repository_decode_field "${entry#*|}" value || die "Repository state has invalid upstream metadata for branch '$name'."
    git check-ref-format "refs/heads/$name" >/dev/null || die "Repository state has an unsafe branch name: $name"
    [[ "$value" == . || -n "${seen_remotes[$value]+set}" ]] \
      || die "Repository branch '$name' references unknown remote '$value'."
    [[ -z "${seen_branch_remotes[$name]+set}" ]] || die "Repository state repeats upstream remote for branch '$name'."
    seen_branch_remotes["$name"]=1
  done
  for entry in "${REPOSITORY_STATE_BRANCH_MERGES[@]}"; do
    repository_decode_field "${entry%%|*}" name || die 'Repository state has an invalid branch name.'
    repository_decode_field "${entry#*|}" value || die "Repository state has invalid merge metadata for branch '$name'."
    git check-ref-format "refs/heads/$name" >/dev/null && git check-ref-format "$value" >/dev/null \
      || die "Repository state has unsafe merge metadata for branch '$name'."
  done
  for entry in "${REPOSITORY_STATE_INCLUDES[@]}"; do
    repository_decode_field "$entry" path || die 'Repository state has an invalid include path.'
    validate_repository_relative_path "$path" || die "Repository state has an unsafe include path: $path"
    [[ -z "${seen_includes[$path]+set}" ]] || die "Repository state repeats include path: $path"
    seen_includes["$path"]=1
  done
  for entry in "${REPOSITORY_STATE_EXCLUDES[@]}"; do
    repository_decode_field "$entry" path || die 'Repository state has an invalid exclude path.'
    validate_repository_relative_path "$path" || die "Repository state has an unsafe exclude path: $path"
    [[ -z "${seen_excludes[$path]+set}" ]] || die "Repository state repeats exclude path: $path"
    seen_excludes["$path"]=1
    for other in "${!seen_includes[@]}"; do
      config_repository_rules_overlap "$path" "$other" \
        && die "Repository state has conflicting include/exclude paths: $other and $path"
    done
  done
  return 0
}

repository_verify_checksums() {
  local artifact="$1" line expected filename actual count=0
  local -A seen=()

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^([0-9a-f]{64})[[:space:]][[:space:]](state\.manifest|worktree\.inventory)$ ]] \
      || die 'Repository checksum manifest contains an invalid entry.'
    expected="${BASH_REMATCH[1]}"; filename="${BASH_REMATCH[2]}"
    [[ -z "${seen[$filename]+set}" ]] || die "Repository checksum repeats $filename."
    seen["$filename"]=1
    actual="$(sha256sum -- "$artifact/$filename")"; actual="${actual%% *}"
    [[ "$actual" == "$expected" ]] || die "Repository artifact checksum failed: $filename"
    ((count += 1))
  done < "$artifact/checksums.manifest"
  (( count == 2 )) || die 'Repository checksum manifest is incomplete.'
}

repository_verify_state_metadata() {
  local artifact="$1" expected_id="${2:-}" line expected filename actual count=0
  local -A seen=()

  [[ -f "$artifact/state.manifest" && ! -L "$artifact/state.manifest" \
    && -f "$artifact/checksums.manifest" && ! -L "$artifact/checksums.manifest" ]] \
    || die 'Repository snapshot metadata is incomplete or unsafe.'
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^([0-9a-f]{64})[[:space:]][[:space:]](state\.manifest|worktree\.inventory)$ ]] \
      || die 'Repository checksum manifest contains an invalid entry.'
    expected="${BASH_REMATCH[1]}"; filename="${BASH_REMATCH[2]}"
    [[ -z "${seen[$filename]+set}" ]] || die "Repository checksum repeats $filename."
    seen["$filename"]=1
    if [[ "$filename" == state.manifest ]]; then
      actual="$(sha256sum -- "$artifact/state.manifest")"; actual="${actual%% *}"
      [[ "$actual" == "$expected" ]] || die 'Repository state metadata failed its checksum.'
    fi
    ((count += 1))
  done < "$artifact/checksums.manifest"
  (( count == 2 )) || die 'Repository checksum manifest is incomplete.'
  repository_state_parse "$artifact/state.manifest" ''
  [[ -z "$expected_id" || "$REPOSITORY_STATE_ID" == "$expected_id" ]] \
    || die "Repository artifact identity is '${REPOSITORY_STATE_ID}', expected '$expected_id'."
}

repository_remove_cached_mirror() {
  local id="$1" cache_root="${2:-$MINT_JELLY_CACHE_DIR/repositories}" mirror

  validate_safe_name "$id" || die "Invalid repository cache identity: $id"
  [[ ! -L "$cache_root" && ( ! -e "$cache_root" || -d "$cache_root" ) ]] \
    || die "Unsafe repository cache root: $cache_root"
  mirror="$cache_root/$id.git"
  [[ ! -e "$mirror" && ! -L "$mirror" ]] && return 0
  [[ -d "$mirror" && ! -L "$mirror" ]] || die "Unsafe repository cache entry: $mirror"
  rm -rf -- "$mirror"
}

repository_prune_cached_mirrors() {
  local cache_root="$1" path name allowed candidate
  shift

  [[ ! -L "$cache_root" && ( ! -e "$cache_root" || -d "$cache_root" ) ]] \
    || die "Unsafe repository cache root: $cache_root"
  [[ -d "$cache_root" ]] || return 0
  shopt -s nullglob
  for path in "$cache_root"/*.git; do
    [[ -d "$path" && ! -L "$path" ]] || die "Unsafe repository cache entry: $path"
    name="${path##*/}"; name="${name%.git}"
    validate_safe_name "$name" || die "Unsafe repository cache identity: $name"
    allowed='false'
    for candidate in "$@"; do [[ "$candidate" != "$name" ]] || allowed='true'; done
    [[ "$allowed" == true ]] || rm -rf -- "$path"
  done
  shopt -u nullglob
}

repository_verify_mirror() {
  local mirror="$1" ref oid encoded decoded target actual_target actual_head_ref actual_head_oid key
  local stash_ref index=0 config_size
  local -A expected=() seen=() expected_symrefs=() seen_config=()

  [[ -d "$mirror" && ! -L "$mirror" ]] || die 'Repository artifact mirror is unsafe.'
  [[ -f "$mirror/config" && ! -L "$mirror/config" \
    && -f "$mirror/HEAD" && ! -L "$mirror/HEAD" ]] \
    || die 'Repository artifact mirror is missing safe configuration metadata.'
  [[ -z "$(find -P "$mirror" -mindepth 1 ! -type d ! -type f -print -quit)" ]] \
    || die 'Repository artifact mirror contains a symbolic link or special file.'
  config_size="$(wc -c < "$mirror/config")"
  (( config_size > 0 && config_size <= 65536 )) \
    || die 'Repository artifact Git configuration has an unsafe size.'
  while IFS= read -r key; do
    [[ -z "${seen_config[$key]+set}" ]] || die "Repository artifact repeats Git configuration: $key"
    seen_config["$key"]=1
    case "$key" in
      core.repositoryformatversion|core.filemode|core.bare|core.logallrefupdates|gc.auto|maintenance.auto|extensions.objectformat) ;;
      *) die "Repository artifact contains unsafe Git configuration: $key" ;;
    esac
  done < <(git config --file "$mirror/config" --no-includes --name-only --list)
  [[ "$(git config --file "$mirror/config" --no-includes --bool --get core.bare 2>/dev/null || true)" == true ]] \
    || die 'Repository artifact mirror does not declare itself bare.'
  [[ "$(git --git-dir="$mirror" rev-parse --is-bare-repository 2>/dev/null || true)" == true ]] \
    || die 'Repository artifact mirror is not a bare repository.'
  [[ "$(git --git-dir="$mirror" rev-parse --show-object-format)" == "$REPOSITORY_STATE_OBJECT_FORMAT" ]] \
    || die 'Repository artifact object format does not match its state.'
  [[ ! -e "$mirror/objects/info/alternates" && ! -L "$mirror/objects/info/alternates" ]] \
    || die 'Repository artifact contains object alternates.'
  [[ ! -e "$mirror/logs" && ! -L "$mirror/logs" ]] || die 'Repository artifact contains reflogs.'
  if [[ -d "$mirror/hooks" ]]; then
    [[ -z "$(find "$mirror/hooks" -mindepth 1 -print -quit)" ]] \
      || die 'Repository artifact contains hooks.'
  fi
  repository_fsck_mirror "$mirror"

  for encoded in "${REPOSITORY_STATE_REFS[@]}"; do
    repository_decode_field "${encoded%%|*}" decoded \
      || die 'Repository state contains an invalid ref name.'
    git check-ref-format "$decoded" >/dev/null || die "Repository state contains an unsafe ref: $decoded"
    [[ "$decoded" != refs/mint-jelly/* ]] || die 'Repository state uses the reserved ref namespace.'
    oid="${encoded#*|}"
    [[ -z "${expected[$decoded]+set}" ]] || die "Repository state repeats ref: $decoded"
    expected["$decoded"]="$oid"
  done
  for encoded in "${REPOSITORY_STATE_SYMREFS[@]}"; do
    repository_decode_field "${encoded%%|*}" decoded || die 'Repository state contains an invalid symbolic ref.'
    repository_decode_field "${encoded#*|}" target || die "Repository state contains an invalid target for $decoded."
    expected_symrefs["$decoded"]="$target"
  done
  if [[ -n "$REPOSITORY_STATE_HEAD_OID" ]]; then
    expected["$REPOSITORY_SYNTHETIC_REF"]="$REPOSITORY_STATE_HEAD_OID"
  fi
  for encoded in "${REPOSITORY_STATE_STASHES[@]}"; do
    printf -v stash_ref 'refs/mint-jelly/stashes/%08d' "$index"
    expected["$stash_ref"]="${encoded%%|*}"
    ((index += 1))
  done
  while read -r oid ref; do
    [[ -n "$ref" ]] || continue
    [[ -n "${expected[$ref]+set}" && "${expected[$ref]}" == "$oid" ]] \
      || die "Repository mirror contains an unexpected ref: $ref"
    seen["$ref"]=1
    actual_target="$(git --git-dir="$mirror" symbolic-ref -q "$ref" 2>/dev/null || true)"
    [[ "$actual_target" == "${expected_symrefs[$ref]-}" ]] \
      || die "Repository mirror symbolic ref does not match its state: $ref"
  done < <(git --git-dir="$mirror" for-each-ref --format='%(objectname) %(refname)')
  for ref in "${!expected[@]}"; do
    [[ -n "${seen[$ref]+set}" ]] || die "Repository mirror is missing ref: $ref"
  done
  actual_head_ref="$(git --git-dir="$mirror" symbolic-ref -q HEAD 2>/dev/null || true)"
  actual_head_oid="$(git --git-dir="$mirror" rev-parse --verify HEAD 2>/dev/null || true)"
  [[ "$actual_head_ref" == "$REPOSITORY_STATE_HEAD_REF" && "$actual_head_oid" == "$REPOSITORY_STATE_HEAD_OID" ]] \
    || die 'Repository mirror HEAD does not match its state.'
}

repository_verify_worktree() {
  local artifact="$1" scratch="$2" list inventory raw encoded kind mode digest decoded

  list="$(mktemp "$scratch/worktree-list.XXXXXX")"
  inventory="$(mktemp "$scratch/worktree-inventory.XXXXXX")"
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    IFS='|' read -r encoded kind mode digest <<< "$raw"
    repository_decode_field "$encoded" decoded true \
      || die 'Repository worktree inventory has an invalid path.'
    repository_validate_worktree_path "$decoded" \
      || die 'Repository worktree inventory has an unsafe path.'
    [[ "$kind" == file || "$kind" == link ]] || die 'Repository worktree inventory has an invalid type.'
    [[ "$mode" =~ ^[0-7]{3,4}$ && "$digest" =~ ^[0-9a-f]{64}$ ]] \
      || die 'Repository worktree inventory has invalid metadata.'
  done < "$artifact/worktree.inventory"
  repository_build_complete_tree_list "$artifact/worktree" "$list"
  repository_inventory_from_list "$artifact/worktree" "$list" "$inventory"
  cmp -s -- "$artifact/worktree.inventory" "$inventory" \
    || die 'Repository worktree content does not match its inventory.'
  rm -f -- "$list" "$inventory"
}

repository_verify_artifact() {
  local artifact="$1" expected_id="${2:-}" scratch="${3:-}" owned_scratch='false' entry
  local -A allowed=( [repository.git]=1 [worktree]=1 [state.manifest]=1 [worktree.inventory]=1 [checksums.manifest]=1 )

  require_cmd base64
  require_cmd git
  require_cmd sha256sum
  [[ -d "$artifact" && ! -L "$artifact" ]] || die "Unsafe repository artifact: $artifact"
  [[ -d "$artifact/repository.git" && ! -L "$artifact/repository.git" \
    && -d "$artifact/worktree" && ! -L "$artifact/worktree" \
    && -f "$artifact/state.manifest" && ! -L "$artifact/state.manifest" \
    && -f "$artifact/worktree.inventory" && ! -L "$artifact/worktree.inventory" \
    && -f "$artifact/checksums.manifest" && ! -L "$artifact/checksums.manifest" ]] \
    || die 'Repository artifact is incomplete or unsafe.'
  shopt -s nullglob dotglob
  for entry in "$artifact"/*; do
    [[ -n "${allowed[${entry##*/}]+set}" ]] || die "Repository artifact contains an unexpected entry: ${entry##*/}"
  done
  shopt -u nullglob dotglob
  if [[ -z "$scratch" ]]; then
    scratch="$(mktemp -d "${TMPDIR:-/tmp}/mint-jelly-repository-verify.XXXXXX")"
    owned_scratch='true'
  else
    [[ -d "$scratch" && ! -L "$scratch" ]] || die "Unsafe repository verification directory: $scratch"
  fi
  repository_verify_checksums "$artifact"
  repository_state_parse "$artifact/state.manifest"
  [[ -z "$expected_id" || "$REPOSITORY_STATE_ID" == "$expected_id" ]] \
    || die "Repository artifact identity is '${REPOSITORY_STATE_ID}', expected '$expected_id'."
  repository_verify_mirror "$artifact/repository.git"
  repository_verify_worktree "$artifact" "$scratch"
  [[ "$owned_scratch" != true ]] || rm -rf -- "$scratch"
}

repository_restore_metadata() {
  local destination="$1" entry encoded_name encoded_value name value
  local -A remote_declared=()

  for entry in "${REPOSITORY_STATE_REMOTES[@]}"; do
    repository_decode_field "$entry" name || die 'Invalid restored remote name.'
    validate_safe_name "$name" || die "Unsafe restored remote name: $name"
    remote_declared["$name"]=1
  done

  for entry in "${REPOSITORY_STATE_REMOTE_URLS[@]}"; do
    encoded_name="${entry%%|*}"; encoded_value="${entry#*|}"
    repository_decode_field "$encoded_name" name || die 'Invalid restored remote name.'
    repository_decode_field "$encoded_value" value || die "Invalid URL for restored remote '$name'."
    [[ -n "${remote_declared[$name]+set}" ]] || die "URL belongs to unknown restored remote '$name'."
    repository_validate_remote_url "$value" || die "Restored remote '$name' has an unsafe URL."
    git -C "$destination" config --add "remote.$name.url" "$value"
  done
  for entry in "${REPOSITORY_STATE_REMOTE_FETCHES[@]}"; do
    encoded_name="${entry%%|*}"; encoded_value="${entry#*|}"
    repository_decode_field "$encoded_name" name || die 'Invalid restored remote name.'
    repository_decode_field "$encoded_value" value || die "Invalid refspec for restored remote '$name'."
    [[ -n "${remote_declared[$name]+set}" ]] || die "Refspec belongs to unknown restored remote '$name'."
    git -C "$destination" config --add "remote.$name.fetch" "$value"
  done
  for entry in "${REPOSITORY_STATE_REMOTE_PUSHURLS[@]}"; do
    encoded_name="${entry%%|*}"; encoded_value="${entry#*|}"
    repository_decode_field "$encoded_name" name || die 'Invalid restored remote name.'
    repository_decode_field "$encoded_value" value || die "Invalid push URL for restored remote '$name'."
    [[ -n "${remote_declared[$name]+set}" ]] || die "Push URL belongs to unknown restored remote '$name'."
    repository_validate_remote_url "$value" || die "Restored remote '$name' has an unsafe push URL."
    git -C "$destination" config --add "remote.$name.pushurl" "$value"
  done
  for entry in "${REPOSITORY_STATE_BRANCH_REMOTES[@]}"; do
    repository_decode_field "${entry%%|*}" name || die 'Invalid restored branch name.'
    repository_decode_field "${entry#*|}" value || die "Invalid upstream remote for branch '$name'."
    git check-ref-format "refs/heads/$name" >/dev/null || die "Unsafe restored branch name: $name"
    [[ "$value" == '.' || -n "${remote_declared[$value]+set}" ]] \
      || die "Branch '$name' references unknown remote '$value'."
    git -C "$destination" config "branch.$name.remote" "$value"
  done
  for entry in "${REPOSITORY_STATE_BRANCH_MERGES[@]}"; do
    repository_decode_field "${entry%%|*}" name || die 'Invalid restored branch name.'
    repository_decode_field "${entry#*|}" value || die "Invalid upstream merge ref for branch '$name'."
    git check-ref-format "$value" >/dev/null || die "Unsafe upstream merge ref: $value"
    git -C "$destination" config --add "branch.$name.merge" "$value"
  done
}

repository_restore_symbolic_refs() {
  local destination="$1" entry ref target

  for entry in "${REPOSITORY_STATE_SYMREFS[@]}"; do
    repository_decode_field "${entry%%|*}" ref || die 'Invalid restored symbolic ref name.'
    repository_decode_field "${entry#*|}" target || die "Invalid target for restored symbolic ref '$ref'."
    git -C "$destination" symbolic-ref "$ref" "$target"
  done
}

repository_restore_stashes() {
  local destination="$1" entry oid message old_oid
  local index

  (( ${#REPOSITORY_STATE_STASHES[@]} > 0 )) || return 0
  git -C "$destination" update-ref --no-deref -d refs/stash 2>/dev/null || true
  rm -f -- "$destination/.git/logs/refs/stash"
  old_oid="$(printf '%0*d' "${#REPOSITORY_STATE_HEAD_OID}" 0)"
  for (( index=${#REPOSITORY_STATE_STASHES[@]}-1; index>=0; index-- )); do
    entry="${REPOSITORY_STATE_STASHES[$index]}"
    oid="${entry%%|*}"
    repository_decode_field "${entry#*|}" message || die 'Invalid restored stash message.'
    git -C "$destination" update-ref --create-reflog -m "$message" refs/stash "$oid" "$old_oid"
    old_oid="$oid"
  done
}

repository_verify_restored_refs() {
  local destination="$1" entry ref oid actual_ref actual_oid head_ref head_oid target actual_target
  local index=0
  local -a actual_stashes=()
  local -A expected=() seen=() expected_symrefs=()

  for entry in "${REPOSITORY_STATE_REFS[@]}"; do
    repository_decode_field "${entry%%|*}" ref \
      || die 'Restored repository state contains an invalid ref name.'
    expected["$ref"]="${entry#*|}"
  done
  for entry in "${REPOSITORY_STATE_SYMREFS[@]}"; do
    repository_decode_field "${entry%%|*}" ref || die 'Restored repository has invalid symbolic ref state.'
    repository_decode_field "${entry#*|}" target || die "Restored repository has invalid symbolic ref target: $ref"
    expected_symrefs["$ref"]="$target"
  done
  while read -r actual_oid actual_ref; do
    [[ -n "$actual_ref" ]] || continue
    [[ "$actual_ref" != refs/mint-jelly/* ]] \
      || die "Restored repository retained a synthetic ref: $actual_ref"
    [[ -n "${expected[$actual_ref]+set}" && "${expected[$actual_ref]}" == "$actual_oid" ]] \
      || die "Restored repository contains an unexpected ref: $actual_ref"
    seen["$actual_ref"]=1
    actual_target="$(git -C "$destination" symbolic-ref -q "$actual_ref" 2>/dev/null || true)"
    [[ "$actual_target" == "${expected_symrefs[$actual_ref]-}" ]] \
      || die "Restored repository symbolic ref does not match its snapshot: $actual_ref"
  done < <(git -C "$destination" for-each-ref --format='%(objectname) %(refname)')
  for ref in "${!expected[@]}"; do
    [[ -n "${seen[$ref]+set}" ]] || die "Restored repository is missing ref: $ref"
  done
  head_ref="$(git -C "$destination" symbolic-ref -q HEAD 2>/dev/null || true)"
  head_oid="$(git -C "$destination" rev-parse --verify HEAD 2>/dev/null || true)"
  [[ "$head_ref" == "$REPOSITORY_STATE_HEAD_REF" && "$head_oid" == "$REPOSITORY_STATE_HEAD_OID" ]] \
    || die 'Restored repository HEAD does not match its snapshot.'
  mapfile -t actual_stashes < <(git -C "$destination" reflog show --format='%H' refs/stash 2>/dev/null || true)
  [[ ${#actual_stashes[@]} -eq ${#REPOSITORY_STATE_STASHES[@]} ]] \
    || die 'Restored repository stash reflog count does not match its snapshot.'
  for (( index=0; index<${#actual_stashes[@]}; index++ )); do
    [[ "${actual_stashes[$index]}" == "${REPOSITORY_STATE_STASHES[$index]%%|*}" ]] \
      || die 'Restored repository stash reflog does not match its snapshot.'
  done
}

repository_restore_artifact() {
  local artifact="$1" destination="$2" expected_id="${3:-}" scratch="${4:-}"
  local already_verified="${5:-false}"
  local template list inventory temporary_head ref
  local owned_scratch='false'

  [[ ! -e "$destination" && ! -L "$destination" ]] \
    || die "Repository staging destination already exists: $destination"
  if [[ -z "$scratch" ]]; then
    scratch="$(mktemp -d "${TMPDIR:-/tmp}/mint-jelly-repository-restore.XXXXXX")"
    owned_scratch='true'
  else
    [[ -d "$scratch" && ! -L "$scratch" ]] || die "Unsafe repository restore scratch directory: $scratch"
  fi
  if [[ "$already_verified" != true ]]; then
    repository_verify_artifact "$artifact" "$expected_id" "$scratch"
  else
    [[ -z "$expected_id" || "$REPOSITORY_STATE_ID" == "$expected_id" ]] \
      || die "Repository artifact identity is '${REPOSITORY_STATE_ID}', expected '$expected_id'."
  fi
  template="$(repository_create_empty_template)"
  git init --quiet --template="$template" --object-format="$REPOSITORY_STATE_OBJECT_FORMAT" "$destination"
  rm -rf -- "$template"
  temporary_head="refs/heads/mint-jelly-restore-$$-$RANDOM"
  while git --git-dir="$artifact/repository.git" show-ref --verify --quiet "$temporary_head"; do
    temporary_head="refs/heads/mint-jelly-restore-$$-$RANDOM"
  done
  git -C "$destination" symbolic-ref HEAD "$temporary_head"
  git -C "$destination" -c protocol.file.allow=always fetch --quiet --force --no-tags --no-write-fetch-head \
    "$artifact/repository.git" '+refs/*:refs/*'
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    git -C "$destination" update-ref --no-deref -d "$ref"
  done < <(git -C "$destination" for-each-ref --format='%(refname)' refs/mint-jelly/)
  repository_restore_symbolic_refs "$destination"
  repository_restore_stashes "$destination"
  if [[ "$REPOSITORY_STATE_HEAD_KIND" == symbolic || "$REPOSITORY_STATE_HEAD_KIND" == unborn ]]; then
    git -C "$destination" symbolic-ref HEAD "$REPOSITORY_STATE_HEAD_REF"
  else
    git -C "$destination" update-ref --no-deref HEAD "$REPOSITORY_STATE_HEAD_OID"
  fi
  if [[ "$REPOSITORY_STATE_HEAD_KIND" != unborn ]]; then
    git -C "$destination" read-tree "$REPOSITORY_STATE_HEAD_OID"
  fi
  rsync --archive --exclude='/.git' -- "$artifact/worktree/" "$destination/"
  repository_restore_metadata "$destination"

  # Compare refs after metadata writes; no original remote is contacted.
  repository_verify_restored_refs "$destination"
  list="$scratch/restored-list"
  inventory="$scratch/restored-inventory"
  repository_build_complete_tree_list "$destination" "$list" true
  repository_inventory_from_list "$destination" "$list" "$inventory"
  cmp -s -- "$artifact/worktree.inventory" "$inventory" \
    || die 'Restored repository worktree failed content verification.'
  [[ "$owned_scratch" != true ]] || rm -rf -- "$scratch"
}
