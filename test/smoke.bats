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

# rec ssh: exercises the full lazy chain rec -> cli.sh -> cli-ssh.sh.
@test "bash: rec ssh help lists the ssh commands" {
  REC_SHELL_ARGS="--norc" load_in bash 'rec ssh help'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rec ssh"* && "$output" == *"add"* ]]
}

@test "zsh: rec ssh dispatches (help)" {
  REC_SHELL_ARGS="-f" load_in zsh 'rec ssh help'
  [ "$status" -eq 0 ]
  [[ "$output" == *"add"* ]]
}

# bare `rec` opens an interactive picker on a TTY; with no TTY (here) it must
# fall back to the textual help rather than hang.
@test "bash: bare rec falls back to help when not a TTY" {
  REC_SHELL_ARGS="--norc" load_in bash 'rec </dev/null'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Commands"* && "$output" == *"doctor"* ]]
}

@test "zsh: bare rec falls back to help when not a TTY" {
  REC_SHELL_ARGS="-f" load_in zsh 'rec </dev/null'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Commands"* && "$output" == *"doctor"* ]]
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

# --- integrations: pnpm + npm-global PATH ----------------------------------

@test "bash: integrations put pnpm + npm-global on PATH (and export PNPM_HOME)" {
  REC_SHELL_ARGS="--norc" load_in bash 'printf "%s\n%s" "$PATH" "$PNPM_HOME"'
  [[ "$output" == *"$REC_HOME/.npm-global/bin"* ]]
  [[ "$output" == *"$REC_HOME/.local/share/pnpm"* ]]
}

# --- reload (the mechanism rec update uses to apply in-place) ---------------

@test "bash: rec reload re-sources and keeps rec defined" {
  REC_SHELL_ARGS="--norc" load_in bash 'rec reload >/dev/null 2>&1; command -v rec'
  [ "$status" -eq 0 ]
}

@test "zsh: rec reload re-sources and keeps rec defined" {
  REC_SHELL_ARGS="-f" load_in zsh 'rec reload >/dev/null 2>&1; command -v rec'
  [ "$status" -eq 0 ]
}

# reload must drop the lazily-loaded CLI groups so a subsequent `rec ...`
# re-sources the freshly updated code (regression: stale cli.sh after update).
@test "bash: rec reload drops the lazy CLI so updated code reloads" {
  REC_SHELL_ARGS="--norc" load_in bash \
    'rec version >/dev/null 2>&1; rec reload >/dev/null 2>&1; command -v __rec_dispatch >/dev/null && echo STALE || echo FRESH'
  [ "$status" -eq 0 ]
  [[ "$output" == *"FRESH"* ]]
}

@test "zsh: rec reload drops the lazy CLI so updated code reloads" {
  REC_SHELL_ARGS="-f" load_in zsh \
    'rec version >/dev/null 2>&1; rec reload >/dev/null 2>&1; command -v __rec_dispatch >/dev/null && echo STALE || echo FRESH'
  [ "$status" -eq 0 ]
  [[ "$output" == *"FRESH"* ]]
}

@test "bash: rec reload also drops the lazy ssh group" {
  REC_SHELL_ARGS="--norc" load_in bash \
    'rec ssh help >/dev/null 2>&1; rec reload >/dev/null 2>&1; command -v __rec_ssh_dispatch >/dev/null && echo STALE || echo FRESH'
  [ "$status" -eq 0 ]
  [[ "$output" == *"FRESH"* ]]
}

@test "bash: rec install help dispatches via cli.sh" {
  REC_SHELL_ARGS="--norc" load_in bash 'rec install help'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rec install"* ]]
  [[ "$output" == *"list"* ]]
}
