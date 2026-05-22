#!/usr/bin/env bats
#
# Integration smoke tests: source the real loader in bash AND zsh and assert
# end-to-end behavior (modules load, CLI works, banner logic, no job-control
# noise, module disabling). Network is never touched (cache is pre-seeded and
# update checks default to "never").

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LOADER="$REPO_ROOT/rec-shell.sh"
  REC_HOME="$(mktemp -d)"
}

teardown() {
  rm -rf "$REC_HOME"
}

# load_in SHELL CODE -> source the loader in SHELL, then run CODE. Isolated HOME.
load_in() {
  local shell="$1"
  shift
  run env -i \
    HOME="$REC_HOME" \
    PATH="$PATH" \
    TERM="${TERM:-xterm}" \
    XDG_CONFIG_HOME="$REC_HOME/.config" \
    XDG_CACHE_HOME="$REC_HOME/.cache" \
    REC_UPDATE_CHECK="${REC_UPDATE_CHECK:-never}" \
    REC_VERSION_URL="${REC_VERSION_URL:-file://$REC_HOME/remote}" \
    REC_VERSION_URL_FALLBACK="" \
    "$shell" $REC_SHELL_ARGS -ic ". '$LOADER'; $*"
}

# --- module + CLI loading --------------------------------------------------

@test "bash: loader defines ported functions and the rec-shell command" {
  REC_SHELL_ARGS="--norc" load_in bash \
    'command -v hosts && command -v extract && command -v mkcd && command -v rec'
  [ "$status" -eq 0 ]
}

@test "zsh: loader defines ported functions and the rec-shell command" {
  REC_SHELL_ARGS="-f" load_in zsh \
    'command -v hosts && command -v extract && command -v mkcd && command -v rec'
  [ "$status" -eq 0 ]
}

@test "bash: rec-shell version prints a semver" {
  REC_SHELL_ARGS="--norc" load_in bash 'rec version'
  [ "$status" -eq 0 ]
  [[ "$output" =~ [0-9]+\.[0-9]+\.[0-9]+ ]]
}

@test "zsh: rec-shell version prints a semver" {
  REC_SHELL_ARGS="-f" load_in zsh 'rec version'
  [ "$status" -eq 0 ]
  [[ "$output" =~ [0-9]+\.[0-9]+\.[0-9]+ ]]
}

# --- update banner ---------------------------------------------------------

@test "bash: shows the update banner when a newer version is cached" {
  mkdir -p "$REC_HOME/.cache/rec-shell"
  printf '%s\n9.9.9\n' "$(date +%s)" >"$REC_HOME/.cache/rec-shell/update"
  REC_UPDATE_CHECK=daily REC_SHELL_ARGS="--norc" load_in bash 'true'
  [[ "$output" == *"9.9.9 available"* ]]
}

@test "zsh: shows the update banner when a newer version is cached" {
  mkdir -p "$REC_HOME/.cache/rec-shell"
  printf '%s\n9.9.9\n' "$(date +%s)" >"$REC_HOME/.cache/rec-shell/update"
  REC_UPDATE_CHECK=daily REC_SHELL_ARGS="-f" load_in zsh 'true'
  [[ "$output" == *"9.9.9 available"* ]]
}

@test "bash: no banner when the cached version is not newer" {
  mkdir -p "$REC_HOME/.cache/rec-shell"
  printf '%s\n0.0.1\n' "$(date +%s)" >"$REC_HOME/.cache/rec-shell/update"
  REC_UPDATE_CHECK=daily REC_SHELL_ARGS="--norc" load_in bash 'true'
  [[ "$output" != *"available"* ]]
}

# --- no job-control noise from the detached background refresh -------------

@test "zsh: no job-control noise on startup even when the bg refresh fires" {
  mkdir -p "$REC_HOME/.cache/rec-shell"
  printf '0\n1.0.0\n' >"$REC_HOME/.cache/rec-shell/update" # epoch 0 => stale => refresh fires
  printf '1.0.0\n' >"$REC_HOME/remote"                     # instant file:// fetch, no network wait
  REC_UPDATE_CHECK=daily REC_SHELL_ARGS="-f" load_in zsh 'true'
  # must not contain a "[1] 12345"-style job notification
  [[ ! "$output" =~ \[[0-9]+\][[:space:]]+[0-9]+ ]]
}

# --- module disabling ------------------------------------------------------

@test "bash: a disabled module does not load" {
  mkdir -p "$REC_HOME/.config/rec-shell"
  printf 'REC_DISABLED_MODULES="ssh"\n' >"$REC_HOME/.config/rec-shell/config"
  REC_SHELL_ARGS="--norc" load_in bash 'command -v extract && ! command -v hosts'
  [ "$status" -eq 0 ]
}

# --- rec git command group -------------------------------------------------

@test "bash: rec git help lists the git commands" {
  REC_SHELL_ARGS="--norc" load_in bash 'rec git help'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rec git"* && "$output" == *"sync"* ]]
}

@test "zsh: rec git dispatches (help)" {
  REC_SHELL_ARGS="-f" load_in zsh 'rec git help'
  [ "$status" -eq 0 ]
  [[ "$output" == *"sync"* ]]
}

@test "zsh: disable then enable round-trips the config" {
  REC_SHELL_ARGS="-f" load_in zsh \
    'rec disable ssh >/dev/null; rec enable ssh >/dev/null; cat "$XDG_CONFIG_HOME/rec-shell/config"'
  [ "$status" -eq 0 ]
  [[ "$output" == *'REC_DISABLED_MODULES=""'* ]]
}

# --- back-compat: the rec-shell alias still dispatches ---------------------

@test "bash: rec-shell alias still works" {
  REC_SHELL_ARGS="--norc" load_in bash 'rec-shell version'
  [ "$status" -eq 0 ]
  [[ "$output" =~ [0-9]+\.[0-9]+\.[0-9]+ ]]
}

@test "zsh: rec-shell alias still works" {
  REC_SHELL_ARGS="-f" load_in zsh 'rec-shell version'
  [ "$status" -eq 0 ]
  [[ "$output" =~ [0-9]+\.[0-9]+\.[0-9]+ ]]
}
