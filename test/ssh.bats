#!/usr/bin/env bats
#
# Tests for the `rec ssh` command group (lib/cli-ssh.sh), in bash and zsh.
# Non-interactive (no TTY): exercises parsing, the frecency/favorites store,
# the add flow (flag form), sorting, and connect routing via a fake `ssh`.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$(mktemp -d)"
  mkdir -p "$T/.ssh" "$T/bin" "$T/.config" "$T/.cache"
  # fake ssh on PATH: echoes its args so we can assert routing (ddev.bats pattern)
  printf '#!/bin/sh\necho "SSH: $*"\n' >"$T/bin/ssh"
  chmod +x "$T/bin/ssh"
  # fixture ~/.ssh/config: two real hosts + a wildcard that must be ignored
  {
    printf 'Host web\n    HostName 10.0.0.1\n    User deploy\n    Port 2222\n\n'
    printf 'Host db\n    HostName db.internal\n    User admin\n\n'
    printf 'Host *\n    ServerAliveInterval 60\n'
  } >"$T/.ssh/config"
}

teardown() {
  rm -rf "$T"
}

# ssh_in SHELL CODE -> source core+ui+cli-ssh in SHELL with an isolated HOME and
# the fake ssh on PATH, then run CODE. REC_UI_PLAIN forces the non-TTY paths.
ssh_in() {
  local shell="$1"
  shift
  run "$shell" -c "
    export HOME='$T' XDG_CONFIG_HOME='$T/.config' XDG_CACHE_HOME='$T/.cache' PATH='$T/bin:$PATH'
    REC_SHELL_DIR='$REPO_ROOT' REC_SHELL_NAME='$shell' REC_UI_PLAIN=1
    . '$REPO_ROOT/lib/core.sh'
    . '$REPO_ROOT/lib/ui.sh'
    . '$REPO_ROOT/lib/cli-ssh.sh'
    $*"
}

# --- parsing ---------------------------------------------------------------

@test "bash: parse_config extracts alias/host/user/port and skips wildcard" {
  ssh_in bash '__rec_ssh_parse_config'
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | awk -F"\t" '$1=="web"{print $2"|"$3"|"$4}')" = "10.0.0.1|deploy|2222" ]
  [ "$(printf '%s\n' "$output" | awk -F"\t" '$1=="db"{print $2"|"$3}')" = "db.internal|admin" ]
  [[ "$output" != *"*"* ]]
}

@test "zsh: parse_config extracts alias/host/user/port and skips wildcard" {
  ssh_in zsh '__rec_ssh_parse_config'
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | awk -F"\t" '$1=="web"{print $2"|"$3"|"$4}')" = "10.0.0.1|deploy|2222" ]
  [[ "$output" != *"*"* ]]
}

@test "bash: missing ssh config yields empty parse, no error" {
  rm -f "$T/.ssh/config"
  ssh_in bash '__rec_ssh_parse_config; printf "rc=%s\n" "$?"'
  [[ "$output" == *"rc=0"* ]]
}

# --- add -------------------------------------------------------------------

@test "bash: add (flags) appends a complete Host block" {
  ssh_in bash '__rec_ssh_add --alias=app --host=1.2.3.4 --user=root --port=22 --key=~/.ssh/id_app'
  [ "$status" -eq 0 ]
  run cat "$T/.ssh/config"
  [[ "$output" == *"Host app"* ]]
  [[ "$output" == *"HostName 1.2.3.4"* ]]
  [[ "$output" == *"User root"* ]]
  [[ "$output" == *"Port 22"* ]]
  [[ "$output" == *"IdentityFile ~/.ssh/id_app"* ]]
}

@test "zsh: add (flags) appends a complete Host block" {
  ssh_in zsh '__rec_ssh_add --alias=app --host=1.2.3.4 --user=root'
  [ "$status" -eq 0 ]
  run cat "$T/.ssh/config"
  [[ "$output" == *"Host app"* && "$output" == *"HostName 1.2.3.4"* ]]
}

@test "bash: add without --key omits IdentityFile" {
  ssh_in bash '__rec_ssh_add --alias=app2 --host=5.6.7.8'
  run cat "$T/.ssh/config"
  [[ "$output" == *"Host app2"* ]]
  [[ "$output" != *"IdentityFile"* ]]
}

@test "bash: add rejects an alias that already exists" {
  ssh_in bash '__rec_ssh_add --alias=web --host=9.9.9.9'
  [ "$status" -ne 0 ]
  [[ "$output" == *exist* ]]
}

# --- favorites + frecency store --------------------------------------------

@test "bash: fav toggles the store on then off" {
  ssh_in bash '__rec_ssh_fav web >/dev/null; __rec_ssh_stats_get web; __rec_ssh_fav web >/dev/null; __rec_ssh_stats_get web'
  [ "$(printf '%s\n' "$output" | sed -n 1p | awk '{print $1}')" = "1" ]
  [ "$(printf '%s\n' "$output" | sed -n 2p | awk '{print $1}')" = "0" ]
}

@test "bash: bump increments count and sets last_epoch" {
  ssh_in bash '__rec_ssh_bump web; __rec_ssh_bump web; __rec_ssh_stats_get web'
  read -r _fav _count _last <<<"$(printf '%s\n' "$output" | tail -1)"
  [ "$_count" = "2" ]
  [ "$_last" -gt 0 ]
}

# --- sorting (favorites first, then frecency; no visible counts) ------------

@test "bash: favorites are pinned before non-favorites" {
  ssh_in bash '__rec_ssh_fav db >/dev/null; __rec_ssh_bump web; __rec_ssh_enumerate_sorted | cut -f1'
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "db" ]
  [ "$(printf '%s\n' "$output" | sed -n 2p)" = "web" ]
}

@test "zsh: favorites are pinned before non-favorites" {
  ssh_in zsh '__rec_ssh_fav db >/dev/null; __rec_ssh_bump web; __rec_ssh_enumerate_sorted | cut -f1'
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "db" ]
}

@test "bash: with no favorites, the most-accessed host comes first" {
  ssh_in bash '__rec_ssh_bump web; __rec_ssh_bump web; __rec_ssh_enumerate_sorted | cut -f1 | sed -n 1p'
  [ "$output" = "web" ]
}

@test "bash: the plain list shows no access count" {
  ssh_in bash '__rec_ssh_bump web; __rec_ssh_bump web; __rec_ssh_bump web; __rec_ssh_list_plain'
  [[ "$output" == *"web"* ]]
  [[ "$output" != *"(3)"* ]]
  [[ "$output" != *"3"* ]]
}

# --- connect ---------------------------------------------------------------

@test "bash: connecting routes to ssh with the alias and bumps frecency" {
  ssh_in bash '__rec_ssh_dispatch web; __rec_ssh_stats_get web'
  [[ "$output" == *"SSH: web"* ]]
  [ "$(printf '%s\n' "$output" | tail -1 | awk '{print $2}')" -ge 1 ]
}

@test "zsh: connecting routes to ssh with the alias" {
  ssh_in zsh '__rec_ssh_dispatch web'
  [[ "$output" == *"SSH: web"* ]]
}

@test "bash: connect passes extra args through to ssh" {
  ssh_in bash '__rec_ssh_dispatch web -v'
  [[ "$output" == *"SSH: web -v"* ]]
}

# --- bare picker fallback (non-TTY) ----------------------------------------

@test "bash: bare ssh lists hosts without hanging when not a TTY" {
  ssh_in bash '__rec_ssh_dispatch </dev/null'
  [ "$status" -eq 0 ]
  [[ "$output" == *"web"* && "$output" == *"db"* ]]
}

@test "zsh: bare ssh lists hosts without hanging when not a TTY" {
  ssh_in zsh '__rec_ssh_dispatch </dev/null'
  [ "$status" -eq 0 ]
  [[ "$output" == *"web"* && "$output" == *"db"* ]]
}
