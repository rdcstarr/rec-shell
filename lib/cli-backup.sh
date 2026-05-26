# shellcheck shell=bash
#
# lib/cli-backup.sh — the `rec backup` command group. Lightweight directory
# snapshots stored as gzipped tarballs in a single configurable folder. No
# new dependencies: tar + gzip are POSIX-essential, du for sizes.
#
#   rec backup [create] <path>     create a new snapshot of <path>
#   rec backup list                 list snapshots (newest first)
#   rec backup restore <id> [DEST]  extract a snapshot
#   rec backup prune [--keep N]     keep the N newest per source-name (default 10)
#
# Default destination: $REC_CACHE_DIR/backups. Override via $REC_BACKUP_DIR.

__rec_backup_dir() {
  printf '%s' "${REC_BACKUP_DIR:-$REC_CACHE_DIR/backups}"
}

# Default ignore-patterns (passed to tar as --exclude).
__rec_backup_default_excludes() {
  printf '%s\n' .git node_modules vendor __pycache__ .venv .DS_Store
}

__rec_backup_dispatch() {
  _rb_cmd="${1:-help}"
  [ $# -gt 0 ] && shift
  # If the first arg is a path that exists, treat it as `rec backup create <path>`.
  if [ -e "$_rb_cmd" ]; then
    __rec_backup_create "$_rb_cmd" "$@"
    return $?
  fi
  case "$_rb_cmd" in
    create) __rec_backup_create "$@" ;;
    list | ls) __rec_backup_list "$@" ;;
    restore) __rec_backup_restore "$@" ;;
    prune) __rec_backup_prune "$@" ;;
    help | --help | -h) __rec_backup_help ;;
    *)
      rec_ui_err "rec backup: unknown command \"$_rb_cmd\""
      printf '\n' >&2
      __rec_backup_help >&2
      return 2
      ;;
  esac
}

__rec_backup_help() {
  local dir
  dir="$(__rec_backup_dir)"
  cat <<EOF
rec backup — directory snapshots

Usage: rec backup <command> [args]

Commands:
  create <path>              Create a gzipped tarball snapshot of <path>.
                             A bare path also works: \`rec backup ./project\`.
  list                       Show snapshots (newest first) with date and size.
  restore <id> [DEST]        Extract snapshot <id> to DEST (default: ./<name>-restored).
  prune [--keep N]           Keep the N newest snapshots per source name (default 10).

Create options:
  --exclude PATTERN          Add a tar --exclude pattern (repeatable).
  --no-default-excludes      Disable default excludes (.git, node_modules,
                             vendor, __pycache__, .venv, .DS_Store).

Destination:  $dir
Override via REC_BACKUP_DIR.
EOF
}

# Internal: list snapshot files newest-first as "<file>\t<size>\t<mtime-iso>".
__rec_backup_files_sorted() {
  local dir
  dir="$(__rec_backup_dir)"
  [ -d "$dir" ] || return 0
  # mac stat -f vs linux stat -c diverge; ls -t is portable enough.
  (cd "$dir" 2>/dev/null && ls -1t -- *.tar.gz 2>/dev/null)
}

__rec_backup_create() {
  local path="" USE_DEFAULTS=yes arg
  local -a EXCLUDES=()
  while [ $# -gt 0 ]; do
    arg="$1"
    case "$arg" in
      -h | --help)
        cat <<'EOF'
Usage: rec backup create <path> [--exclude PATTERN ...] [--no-default-excludes]

Create a gzipped tarball snapshot of <path> in the backup destination.
EOF
        return 0
        ;;
      --no-default-excludes) USE_DEFAULTS=no ;;
      --exclude)
        shift
        EXCLUDES+=("${1:-}")
        ;;
      --exclude=*) EXCLUDES+=("${arg#*=}") ;;
      -*)
        rec_ui_err "rec backup create: unknown flag '$arg'"
        return 2
        ;;
      *) [ -z "$path" ] && path="$arg" ;;
    esac
    shift
  done
  if [ -z "$path" ]; then
    rec_ui_err "rec backup create: <path> is required"
    return 2
  fi
  if [ ! -e "$path" ]; then
    rec_ui_err "rec backup create: '$path' does not exist"
    return 1
  fi
  local dir base ts dest parent name
  dir="$(__rec_backup_dir)"
  mkdir -p "$dir" || {
    rec_ui_err "cannot create backup dir $dir"
    return 1
  }
  # Resolve to absolute, then split into parent + name so tar can `-C` into it.
  base="$(cd "$(dirname "$path")" 2>/dev/null && pwd)" || base="$(dirname "$path")"
  name="$(basename "$path")"
  parent="$base"
  ts="$(date +%Y%m%d-%H%M%S)"
  dest="$dir/$name-$ts.tar.gz"

  local -a tar_args=(-C "$parent")
  if [ "$USE_DEFAULTS" = yes ]; then
    local pat
    while IFS= read -r pat; do
      tar_args+=(--exclude="$pat")
    done <<EOF
$(__rec_backup_default_excludes)
EOF
  fi
  local e
  for e in "${EXCLUDES[@]}"; do
    [ -n "$e" ] && tar_args+=(--exclude="$e")
  done
  tar_args+=(-czf "$dest" "$name")

  rec_ui_step "backing up $parent/$name -> $dest"
  if ! tar "${tar_args[@]}"; then
    rec_ui_err "tar failed"
    rm -f "$dest"
    return 1
  fi
  local size
  size="$(du -h "$dest" 2>/dev/null | awk '{print $1}')"
  rec_ui_ok "snapshot created ($size)"
  rec_ui_kv "file" "$dest"
}

__rec_backup_list() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -h | --help)
        printf 'Usage: rec backup list\n'
        return 0
        ;;
    esac
  done
  local dir f size mtime
  dir="$(__rec_backup_dir)"
  if [ ! -d "$dir" ] || [ -z "$(__rec_backup_files_sorted)" ]; then
    rec_ui_info "no snapshots in $dir"
    return 0
  fi
  rec_ui_heading "snapshots in $dir"
  {
    printf 'ID\tSIZE\tDATE\n'
    __rec_backup_files_sorted | while IFS= read -r f; do
      size="$(du -h "$dir/$f" 2>/dev/null | awk '{print $1}')"
      # filenames are timestamped strings we generated, so basic ls is safe
      # shellcheck disable=SC2012
      mtime="$(ls -ld -- "$dir/$f" 2>/dev/null | awk '{print $6, $7, $8}')"
      printf '%s\t%s\t%s\n' "$f" "${size:-?}" "${mtime:-?}"
    done
  } | column -t -s '	'
}

__rec_backup_restore() {
  local id="" dest="" arg
  for arg in "$@"; do
    case "$arg" in
      -h | --help)
        printf 'Usage: rec backup restore <id> [DEST]\n'
        return 0
        ;;
      -*)
        rec_ui_err "rec backup restore: unknown flag '$arg'"
        return 2
        ;;
      *)
        if [ -z "$id" ]; then
          id="$arg"
        elif [ -z "$dest" ]; then
          dest="$arg"
        else
          rec_ui_err "rec backup restore: extra argument '$arg'"
          return 2
        fi
        ;;
    esac
  done
  if [ -z "$id" ]; then
    rec_ui_err "rec backup restore: <id> is required (see \`rec backup list\`)"
    return 2
  fi
  local dir src
  dir="$(__rec_backup_dir)"
  case "$id" in
    *.tar.gz) src="$dir/$id" ;;
    *) src="$dir/$id" ;;
  esac
  if [ ! -f "$src" ]; then
    rec_ui_err "rec backup restore: '$id' not found in $dir"
    return 1
  fi
  if [ -z "$dest" ]; then
    # Strip the -YYYYMMDD-HHMMSS.tar.gz tail to get the source name.
    local name
    name="$(basename "$src" .tar.gz)"
    name="${name%-[0-9]*-[0-9]*}"
    dest="./$name-restored"
  fi
  if [ -e "$dest" ]; then
    if rec_ui_interactive_load && __rec_ui_interactive; then
      rec_ui_confirm "Destination '$dest' exists. Overwrite contents?" no || {
        rec_ui_info aborted
        return 0
      }
    else
      rec_ui_err "destination '$dest' already exists (run interactively to confirm overwrite)"
      return 1
    fi
  fi
  mkdir -p "$dest" || {
    rec_ui_err "cannot create $dest"
    return 1
  }
  rec_ui_step "extracting $src -> $dest"
  if ! tar -xzf "$src" -C "$dest"; then
    rec_ui_err "tar extract failed"
    return 1
  fi
  rec_ui_ok "restored to $dest"
}

__rec_backup_prune() {
  local KEEP=10 arg
  for arg in "$@"; do
    case "$arg" in
      -h | --help)
        printf 'Usage: rec backup prune [--keep N]\n\nKeeps the N newest snapshots per source name.\n'
        return 0
        ;;
      --keep=*) KEEP="${arg#*=}" ;;
      --keep)
        # value comes from next iteration; mark sentinel
        KEEP=NEXT
        ;;
      *)
        if [ "$KEEP" = NEXT ]; then
          KEEP="$arg"
        else
          rec_ui_err "rec backup prune: unknown arg '$arg'"
          return 2
        fi
        ;;
    esac
  done
  case "$KEEP" in
    NEXT)
      rec_ui_err "--keep requires a value"
      return 2
      ;;
    *[!0-9]*)
      rec_ui_err "--keep '$KEEP' is not a number"
      return 2
      ;;
  esac

  local dir
  dir="$(__rec_backup_dir)"
  [ -d "$dir" ] || {
    rec_ui_info "no snapshots"
    return 0
  }

  # Group by source-name (everything before the trailing -YYYYMMDD-HHMMSS.tar.gz),
  # keep the newest KEEP per group, delete the rest.
  local groups
  groups="$(__rec_backup_files_sorted \
    | sed -E 's/-[0-9]{8}-[0-9]{6}\.tar\.gz$//' \
    | sort -u)"
  local g count f base
  printf '%s\n' "$groups" | while IFS= read -r g; do
    [ -n "$g" ] || continue
    count=0
    __rec_backup_files_sorted | while IFS= read -r f; do
      base="$(printf '%s' "$f" | sed -E 's/-[0-9]{8}-[0-9]{6}\.tar\.gz$//')"
      if [ "$base" = "$g" ]; then
        count=$((count + 1))
        if [ "$count" -gt "$KEEP" ]; then
          printf '%s\n' "$f"
        fi
      fi
    done
  done | while IFS= read -r f; do
    [ -n "$f" ] || continue
    rec_ui_warn_out "removing $f"
    rm -f -- "$dir/$f"
  done
  rec_ui_ok "prune complete (kept $KEEP per source)"
}
