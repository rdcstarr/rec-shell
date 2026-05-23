#!/usr/bin/env bats
#
# Tests for scripts/release.sh — the rec-shell maintainer release tool. Runs
# against a local bare origin so push works without network.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RELEASE="$REPO_ROOT/scripts/release.sh"
  T="$(mktemp -d)"
  export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
  git config -f "$T/gitconfig" user.email t@example.com
  git config -f "$T/gitconfig" user.name tester
  git config -f "$T/gitconfig" init.defaultBranch main

  git init -q --bare "$T/origin.git"
  git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
  (
    cd "$T/repo"
    printf '1.0.0\n' >VERSION
    printf '# loader\n' >rec-shell.sh
    git add -A && git commit -qm init && git push -q -u origin main
  )
}

teardown() {
  rm -rf "$T"
}

rel() { run bash -c "cd '$T/repo'; bash '$RELEASE' $*"; }
ver() { cat "$T/repo/VERSION"; }
has_tag() { git -C "$T/repo" rev-parse "$1" >/dev/null 2>&1; }
origin_has_tag() { git -C "$T/origin.git" tag | grep -qx "$1"; }

@test "release --patch bumps VERSION, commits, tags, pushes" {
  rel --patch
  [ "$status" -eq 0 ]
  [ "$(ver)" = "1.0.1" ]
  has_tag v1.0.1
  origin_has_tag v1.0.1
  [ "$(git -C "$T/repo" log -1 --pretty=%s)" = "release v1.0.1" ]
}

@test "release --minor bumps the minor and resets patch" {
  rel --minor
  [ "$(ver)" = "1.1.0" ]
  has_tag v1.1.0
}

@test "release --major bumps the major and resets the rest" {
  rel --major
  [ "$(ver)" = "2.0.0" ]
  has_tag v2.0.0
}

@test "release --v sets an exact version" {
  rel --v=2.5.3
  [ "$(ver)" = "2.5.3" ]
  has_tag v2.5.3
}

@test "release --v equal to the current VERSION tags without an extra commit" {
  rel --v=1.0.0
  [ "$status" -eq 0 ]
  has_tag v1.0.0
  [ "$(git -C "$T/repo" rev-list --count HEAD)" = "1" ]
}

@test "release -n (dry-run) changes nothing" {
  rel --minor -n
  [ "$status" -eq 0 ]
  [ "$(ver)" = "1.0.0" ]
  ! has_tag v1.1.0
}

@test "release refuses a dirty working tree" {
  echo x >"$T/repo/extra.txt"
  (cd "$T/repo" && git add extra.txt)
  rel --patch
  [ "$status" -ne 0 ]
}

@test "release refuses when the tag already exists" {
  (cd "$T/repo" && git tag v1.0.1)
  rel --patch
  [ "$status" -ne 0 ]
}

@test "release refuses outside the rec-shell repo (no VERSION)" {
  rm -f "$T/repo/VERSION"
  rel --patch
  [ "$status" -ne 0 ]
}
