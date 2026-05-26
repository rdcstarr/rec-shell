#!/usr/bin/env bats
#
# Tests for `rec backup` (lib/cli-backup.sh). Uses a real tarball round-trip
# against a temp source tree so the create + list + restore flow is exercised
# end-to-end. tar is a POSIX essential, so no stubs are needed.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$(mktemp -d)"
  SRC="$T/src"
  DEST="$T/dest"
  mkdir -p "$SRC" "$DEST"
  echo "hello" >"$SRC/a.txt"
  echo "world" >"$SRC/b.txt"
  mkdir -p "$SRC/.git" && echo gitstuff >"$SRC/.git/HEAD"
}
teardown() { rm -rf "$T"; }

backup_in() {
  local shell="$1"
  shift
  run "$shell" -c "
    export HOME='$T' PATH='/usr/bin:/bin' REC_BACKUP_DIR='$DEST'
    REC_SHELL_DIR='$REPO_ROOT' REC_SHELL_NAME='$shell' REC_UI_PLAIN=1
    . '$REPO_ROOT/lib/core.sh'
    . '$REPO_ROOT/lib/ui.sh'
    . '$REPO_ROOT/lib/cli-backup.sh'
    $*"
}

@test "bash: create then list shows the snapshot" {
  backup_in bash "__rec_backup_create '$SRC' && __rec_backup_list"
  [ "$status" -eq 0 ]
  [[ "$output" == *"src-"*.tar.gz* ]]
}

@test "bash: default excludes .git" {
  backup_in bash "__rec_backup_create '$SRC'"
  [ "$status" -eq 0 ]
  archive="$(ls -1 "$DEST"/*.tar.gz | head -n1)"
  run tar -tzf "$archive"
  [[ "$output" != *".git"* ]]
}

@test "bash: --no-default-excludes keeps .git" {
  backup_in bash "__rec_backup_create '$SRC' --no-default-excludes"
  archive="$(ls -1 "$DEST"/*.tar.gz | head -n1)"
  run tar -tzf "$archive"
  [[ "$output" == *".git"* ]]
}

@test "bash: create on missing path returns 1" {
  backup_in bash "__rec_backup_create '$T/does/not/exist'"
  [ "$status" -eq 1 ]
}

@test "bash: create without an argument returns 2" {
  backup_in bash '__rec_backup_create'
  [ "$status" -eq 2 ]
}

@test "bash: list on empty backup dir is a no-op" {
  rm -rf "$DEST"
  backup_in bash '__rec_backup_list'
  [ "$status" -eq 0 ]
}

@test "bash: restore round-trips the content" {
  backup_in bash "__rec_backup_create '$SRC'"
  archive_basename="$(ls -1 "$DEST" | head -n1)"
  backup_in bash "__rec_backup_restore '$archive_basename' '$T/back'"
  [ "$status" -eq 0 ]
  [ -f "$T/back/src/a.txt" ]
  run cat "$T/back/src/a.txt"
  [ "$output" = "hello" ]
}

@test "bash: prune keeps only the newest N per source" {
  for _ in 1 2 3 4; do
    backup_in bash "__rec_backup_create '$SRC'"
    sleep 1
  done
  before="$(ls -1 "$DEST"/*.tar.gz | wc -l | awk '{print $1}')"
  [ "$before" -eq 4 ]
  backup_in bash '__rec_backup_prune --keep 2'
  after="$(ls -1 "$DEST"/*.tar.gz | wc -l | awk '{print $1}')"
  [ "$after" -eq 2 ]
}

@test "bash: unknown subcommand returns 2" {
  backup_in bash '__rec_backup_dispatch bogus'
  [ "$status" -eq 2 ]
}

@test "bash: help mentions all verbs" {
  backup_in bash '__rec_backup_help'
  [[ "$output" == *"create"* && "$output" == *"list"* && "$output" == *"restore"* && "$output" == *"prune"* ]]
}
