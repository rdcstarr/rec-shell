#!/usr/bin/env bats
#
# Tests for `rec install` (lib/cli-install.sh) and the install.sh
# --tools-only flag.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$(mktemp -d)"
  mkdir -p "$T/bin"
}
teardown() { rm -rf "$T"; }

@test "install.sh --tools-only --no-tools is a no-op (exits 0 without cloning)" {
  # PATH gives bash access to coreutils but the script never reaches a clone:
  # --no-tools combined with --tools-only short-circuits everything.
  run bash "$REPO_ROOT/install.sh" --tools-only --no-tools --unattended
  [ "$status" -eq 0 ]
  # Must NOT have hit clone_or_update — its banner contains "Cloning" or
  # "Updating existing checkout".
  [[ "$output" != *"Cloning"* ]]
  [[ "$output" != *"Updating existing checkout"* ]]
}
