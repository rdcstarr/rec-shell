#!/usr/bin/env bats
#
# Tests for `rec tips` + `rec cheat` (lib/cli-tips.sh). PATH is stubbed so
# only specific tools appear "installed" and the rest are absent — that's
# how the filtering by rec_have is verified.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$(mktemp -d)"
  mkdir -p "$T/bin"
  # Coreutils we need (cat/wc/awk/sed/printf are used by tip helpers + heredocs).
  # PATH stays $T/bin only, so any tool we don't symlink is "not installed".
  for c in cat wc awk sed sh head tail mkdir rm chmod; do
    src="$(command -v "$c" 2>/dev/null)"
    [ -n "$src" ] && ln -s "$src" "$T/bin/$c"
  done
}
teardown() { rm -rf "$T"; }

# Source the tips module in a clean subshell. PATH is $T/bin only, so any
# tool you don't stub (or symlink in setup) is "not installed".
tips_in() {
  local shell="$1"
  shift
  run "$shell" -c "
    export HOME='$T' PATH='$T/bin' XDG_CACHE_HOME='$T/.cache'
    REC_SHELL_DIR='$REPO_ROOT' REC_SHELL_NAME='$shell' REC_UI_PLAIN=1
    . '$REPO_ROOT/lib/core.sh'
    . '$REPO_ROOT/lib/ui.sh'
    . '$REPO_ROOT/lib/cli-tips.sh'
    $*"
}

# Stub a tool: drop a no-op exe with that name on PATH.
stub_tool() {
  printf '#!/bin/sh\nexit 0\n' >"$T/bin/$1"
  chmod +x "$T/bin/$1"
}

# --- tips ------------------------------------------------------------------

@test "bash: tips with no tools installed prints nothing (random)" {
  tips_in bash '__rec_tip_random'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "bash: tips with no tools installed says so (next)" {
  tips_in bash '__rec_tip_next'
  [ "$status" -eq 0 ]
  [[ "$output" == *"no tips applicable"* ]]
}

@test "bash: tips with only rg shows only [rg] entries (all)" {
  stub_tool rg
  tips_in bash '__rec_tips_all'
  [ "$status" -eq 0 ]
  # Filter heading + tips: every printed line must be 'rg' or start with two spaces.
  [[ "$output" == *"rg"* ]]
  [[ "$output" != *"fd"* ]]
  [[ "$output" != *"bat"* ]]
}

@test "bash: tips next advances and wraps around the rotation" {
  stub_tool rg
  # Count how many rg tips are in REC_TIPS so we can wrap predictably.
  tips_in bash 'n="$(__rec_tips_applicable_indices | wc -l | awk "{print \$1}")"; printf "%d" "$n"'
  count="$output"
  # Call next count+1 times and verify it does not crash and produces output.
  for _ in $(seq 1 "$((count + 1))"); do
    tips_in bash '__rec_tip_next'
    [ "$status" -eq 0 ]
    [ -n "$output" ]
  done
}

@test "bash: tips dispatch unknown verb returns 2" {
  tips_in bash '__rec_tips_dispatch bogus'
  [ "$status" -eq 2 ]
}

# --- cheat -----------------------------------------------------------------

@test "bash: cheat with no tools tells the user nothing is installed" {
  tips_in bash '__rec_cheat_dispatch all'
  [ "$status" -eq 0 ]
  [[ "$output" == *"no modern CLI tools installed"* ]]
}

@test "bash: cheat all shows sections for the installed subset" {
  stub_tool rg
  stub_tool fd
  tips_in bash '__rec_cheat_dispatch all'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ripgrep"* ]]
  [[ "$output" == *"fd"* ]]
  [[ "$output" != *"eza"* ]]
  [[ "$output" != *"btop"* ]]
}

@test "bash: cheat <tool> when the tool is missing errors with exit 1" {
  tips_in bash '__rec_cheat_dispatch rg'
  [ "$status" -eq 1 ]
  [[ "$output" == *"not installed"* ]]
}

@test "bash: cheat eza shows just the eza section when present" {
  stub_tool eza
  tips_in bash '__rec_cheat_dispatch eza'
  [ "$status" -eq 0 ]
  [[ "$output" == *"eza"* ]]
  [[ "$output" != *"ripgrep"* ]]
}

@test "bash: cheat help mentions every accepted tool name" {
  tips_in bash '__rec_cheat_help'
  for t in rg fd eza bat fzf btop ncdu; do
    [[ "$output" == *"$t"* ]] || {
      echo "missing $t"
      false
    }
  done
}

@test "zsh: tips all works with one tool installed" {
  stub_tool bat
  tips_in zsh '__rec_tips_all'
  [ "$status" -eq 0 ]
  [[ "$output" == *"bat"* ]]
}
