#!/usr/bin/env bats
#
# Tests for modules/ddev.sh — the DDEV smart commands. A fake `ddev` (and,
# where needed, a fake host binary) is put on PATH so routing can be asserted
# without a real ddev install.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$(mktemp -d)"
  mkdir -p "$T/bin"
  printf '#!/bin/sh\necho "DDEV: $*"\n' >"$T/bin/ddev"
  chmod +x "$T/bin/ddev"
  CORE="$REPO_ROOT/lib/core.sh"
  MOD="$REPO_ROOT/modules/ddev.sh"
}

teardown() {
  rm -rf "$T"
}

@test "_in_ddev_project: true in a project root" {
  mkdir -p "$T/p/.ddev"
  : >"$T/p/.ddev/config.yaml"
  run bash -c "cd '$T/p'; . '$CORE'; . '$MOD'; _in_ddev_project"
  [ "$status" -eq 0 ]
}

@test "_in_ddev_project: true one level below the project root" {
  mkdir -p "$T/p/.ddev" "$T/p/web"
  : >"$T/p/.ddev/config.yaml"
  run bash -c "cd '$T/p/web'; . '$CORE'; . '$MOD'; _in_ddev_project"
  [ "$status" -eq 0 ]
}

@test "_in_ddev_project: false outside a project" {
  run bash -c "cd '$T'; . '$CORE'; . '$MOD'; _in_ddev_project"
  [ "$status" -ne 0 ]
}

@test "bash: wrappers are defined when ddev is installed" {
  run bash -c "PATH='$T/bin:\$PATH'; . '$CORE'; . '$MOD'; type -t php; type -t artisan; type -t npm"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c function)" -eq 3 ]
}

@test "bash: wrappers are NOT defined when ddev is absent" {
  run bash -c "PATH='/usr/bin:/bin'; . '$CORE'; . '$MOD'; [ \"\$(type -t php)\" = function ] && echo yes || echo no"
  [ "$output" = no ]
}

@test "zsh: wrappers are defined when ddev is installed" {
  run zsh -c "PATH='$T/bin:\$PATH'; . '$CORE'; . '$MOD'; whence -w php"
  [[ "$output" == *function* ]]
}

@test "bash: php routes through 'ddev exec' inside a project" {
  mkdir -p "$T/p/.ddev"
  : >"$T/p/.ddev/config.yaml"
  run bash -c "PATH='$T/bin:\$PATH'; cd '$T/p'; . '$CORE'; . '$MOD'; php -v"
  [[ "$output" == *"DDEV: exec php -v"* ]]
}

@test "bash: artisan routes to 'ddev artisan' inside a project" {
  mkdir -p "$T/p/.ddev"
  : >"$T/p/.ddev/config.yaml"
  run bash -c "PATH='$T/bin:\$PATH'; cd '$T/p'; . '$CORE'; . '$MOD'; artisan migrate"
  [[ "$output" == *"DDEV: artisan migrate"* ]]
}

@test "bash: php uses the host binary outside a project (no recursion)" {
  printf '#!/bin/sh\necho "HOST: $*"\n' >"$T/bin/php"
  chmod +x "$T/bin/php"
  run bash -c "PATH='$T/bin:\$PATH'; cd '$T'; . '$CORE'; . '$MOD'; php -v"
  [[ "$output" == *"HOST: -v"* ]]
}
