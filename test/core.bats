#!/usr/bin/env bats
#
# Unit tests for lib/core.sh helpers.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  REC_TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$REC_TMP"
}

@test "rec_installed_version reads VERSION and strips a leading v" {
  printf 'v1.2.3\n' >"$REC_TMP/VERSION"
  run sh -c "REC_SHELL_DIR='$REC_TMP'; . '$REPO_ROOT/lib/core.sh'; rec_installed_version"
  [ "$status" -eq 0 ]
  [ "$output" = "1.2.3" ]
}

@test "rec_installed_version trims surrounding whitespace" {
  printf '  2.0.0  \n' >"$REC_TMP/VERSION"
  run sh -c "REC_SHELL_DIR='$REC_TMP'; . '$REPO_ROOT/lib/core.sh'; rec_installed_version"
  [ "$status" -eq 0 ]
  [ "$output" = "2.0.0" ]
}

@test "rec_installed_version fails when VERSION is missing" {
  run sh -c "REC_SHELL_DIR='$REC_TMP'; . '$REPO_ROOT/lib/core.sh'; rec_installed_version"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "rec_have detects an existing command and rejects a missing one" {
  run sh -c ". '$REPO_ROOT/lib/core.sh'; rec_have sh && ! rec_have definitely_not_a_real_cmd_xyz"
  [ "$status" -eq 0 ]
}

@test "core sets REC_OS to a known value" {
  run sh -c ". '$REPO_ROOT/lib/core.sh'; printf '%s' \"\$REC_OS\""
  [ "$status" -eq 0 ]
  case "$output" in
    mac | linux | other) : ;;
    *) false ;;
  esac
}
