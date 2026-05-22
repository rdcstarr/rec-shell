#!/usr/bin/env bats
#
# Unit tests for lib/semver.sh — rec_semver_gt A B.
# Every case is exercised in sh, bash AND zsh, because zsh's word-splitting
# differs from sh/bash and a sh-only test would miss zsh-specific breakage.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

# expect_status A B WANT -> assert rec_semver_gt A B exits WANT in all shells
expect_status() {
  local s
  for s in sh bash zsh; do
    command -v "$s" >/dev/null 2>&1 || continue
    run "$s" -c ". '$REPO_ROOT/lib/semver.sh'; rec_semver_gt '$1' '$2'"
    if [ "$status" -ne "$3" ]; then
      echo "shell=$s: rec_semver_gt $1 $2 -> $status (wanted $3)"
      return 1
    fi
  done
}

@test "patch: 1.5.0 is newer than 1.4.9" {
  expect_status 1.5.0 1.4.9 0
}

@test "equal versions are not newer" {
  expect_status 1.4.0 1.4.0 1
}

@test "older is not newer than newer" {
  expect_status 1.4.9 1.5.0 1
}

@test "numeric (not lexical) field compare: 1.10.0 newer than 1.9.0" {
  expect_status 1.10.0 1.9.0 0
}

@test "major bump: 2.0.0 newer than 1.99.99" {
  expect_status 2.0.0 1.99.99 0
}

@test "leading v is stripped on both sides" {
  expect_status v1.5.0 v1.4.0 0
}

@test "missing fields default to zero: v1.4 equals 1.4.0 (not newer)" {
  expect_status v1.4 1.4.0 1
}

@test "missing fields default to zero: 1.4 newer than 1.3.9" {
  expect_status 1.4 1.3.9 0
}

@test "prerelease suffix is ignored: 1.2.3-rc1 not newer than 1.2.3" {
  expect_status 1.2.3-rc1 1.2.3 1
}

@test "build metadata is ignored: 1.2.3+build5 not newer than 1.2.3" {
  expect_status 1.2.3+build5 1.2.3 1
}
