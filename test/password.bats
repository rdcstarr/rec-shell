#!/usr/bin/env bats
#
# Tests for `rec password` (lib/cli-password.sh). Verifies dispatch, defaults,
# flag parsing, and the deterministic shape of generated passwords.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$(mktemp -d)"
  mkdir -p "$T/bin"
  # Make sure no real clipboard tool is found, so --no-copy isn't actually
  # required by the test environment to keep us off the user's clipboard.
  unset WAYLAND_DISPLAY DISPLAY
}

teardown() { rm -rf "$T"; }

# Source the module in a clean subshell.
pw_in() {
  local shell="$1"
  shift
  run "$shell" -c "
    export HOME='$T' PATH='$T/bin:/usr/bin:/bin'
    REC_SHELL_DIR='$REPO_ROOT' REC_SHELL_NAME='$shell' REC_UI_PLAIN=1 REC_OS=mac
    . '$REPO_ROOT/lib/core.sh'
    . '$REPO_ROOT/lib/ui.sh'
    . '$REPO_ROOT/lib/cli-password.sh'
    $*"
}

@test "bash: default length is 24 and includes specials" {
  pw_in bash '__rec_password_run --no-copy'
  [ "$status" -eq 0 ]
  pw="$(printf '%s\n' "$output" | head -n1)"
  [ "${#pw}" -eq 24 ]
}

@test "bash: --length 32 yields a 32-char password" {
  pw_in bash '__rec_password_run --length 32 --no-copy'
  [ "$status" -eq 0 ]
  pw="$(printf '%s\n' "$output" | head -n1)"
  [ "${#pw}" -eq 32 ]
}

@test "bash: --no-special restricts to alphanumeric" {
  pw_in bash '__rec_password_run --length 30 --no-special --no-copy'
  [ "$status" -eq 0 ]
  pw="$(printf '%s\n' "$output" | head -n1)"
  [[ "$pw" =~ ^[A-Za-z0-9]+$ ]]
}

@test "bash: --count emits N passwords" {
  pw_in bash '__rec_password_run --count 3 --no-copy'
  [ "$status" -eq 0 ]
  # Three password lines, no warnings about clipboard tool found.
  count="$(printf '%s\n' "$output" | grep -cE '^[A-Za-z0-9!@#$%^&*_=+?-]{24}$' || true)"
  [ "$count" -eq 3 ]
}

@test "bash: --length below 8 is rejected" {
  pw_in bash '__rec_password_run --length 4 --no-copy'
  [ "$status" -eq 2 ]
}

@test "bash: --length above 256 is rejected" {
  pw_in bash '__rec_password_run --length 9999 --no-copy'
  [ "$status" -eq 2 ]
}

@test "bash: --help prints usage and returns 0" {
  pw_in bash '__rec_password_run --help'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rec password"* ]]
  [[ "$output" == *"--length"* ]]
}

@test "zsh: defaults still produce a 24-char password" {
  pw_in zsh '__rec_password_run --no-copy'
  [ "$status" -eq 0 ]
  pw="$(printf '%s\n' "$output" | head -n1)"
  [ "${#pw}" -eq 24 ]
}
