#!/usr/bin/env bats
#
# Tests for `rec sys` (lib/cli-sys.sh). Focused on dispatch + help + error
# paths; the actual ps/df/free output is deferred to the host's tools.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$(mktemp -d)"
}
teardown() { rm -rf "$T"; }

sys_in() {
  local shell="$1"
  shift
  run "$shell" -c "
    export HOME='$T' PATH='/usr/bin:/bin'
    REC_SHELL_DIR='$REPO_ROOT' REC_SHELL_NAME='$shell' REC_UI_PLAIN=1
    . '$REPO_ROOT/lib/core.sh'
    . '$REPO_ROOT/lib/ui.sh'
    . '$REPO_ROOT/lib/cli-sys.sh'
    $*"
}

@test "bash: help lists all verbs" {
  sys_in bash '__rec_sys_help'
  [ "$status" -eq 0 ]
  [[ "$output" == *"disk"* ]]
  [[ "$output" == *"mem"* ]]
  [[ "$output" == *"top"* ]]
  [[ "$output" == *"ports"* ]]
  [[ "$output" == *"uptime"* ]]
}

@test "bash: unknown subcommand returns 2" {
  sys_in bash '__rec_sys_dispatch bogus'
  [ "$status" -eq 2 ]
}

@test "bash: top with non-numeric argument returns 2" {
  sys_in bash '__rec_sys_top abc'
  [ "$status" -eq 2 ]
}

@test "bash: disk on missing directory returns 1" {
  sys_in bash '__rec_sys_disk /no/such/place/at/all'
  [ "$status" -eq 1 ]
}

@test "bash: uptime runs and prints something" {
  sys_in bash '__rec_sys_uptime'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}
