#!/usr/bin/env bats
#
# Integration tests for the `rec update` command against a local bare "origin"
# with two tagged versions. Exercised in bash and zsh.

setup() {
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$(mktemp -d)"
  export GIT_CONFIG_GLOBAL="$T/gc" GIT_CONFIG_SYSTEM=/dev/null
  git config -f "$T/gc" user.email t@example.com
  git config -f "$T/gc" user.name tester
  git config -f "$T/gc" init.defaultBranch main
  git config -f "$T/gc" advice.detachedHead false

  git init -q --bare "$T/origin.git"
  git clone -q "$T/origin.git" "$T/src"
  cp "$SRC/rec-shell.sh" "$T/src"
  cp -R "$SRC/lib" "$T/src"
  cp -R "$SRC/modules" "$T/src"
  (
    cd "$T/src"
    printf '0.0.1\n' >VERSION
    git add -A
    GIT_COMMITTER_DATE="2020-01-01T00:00:00" git commit -qm v1
    git tag v0.0.1
    printf '0.0.2\n' >VERSION
    git add -A
    GIT_COMMITTER_DATE="2020-06-01T00:00:00" git commit -qm v2
    git tag v0.0.2
    git push -q origin HEAD:main --tags
  )
  git clone -q "$T/origin.git" "$T/inst"
  git -C "$T/inst" checkout -q v0.0.1
}

teardown() {
  rm -rf "$T"
}

# up_in SHELL ARGS CODE -> source the installed clone's loader and run CODE.
up_in() {
  run env -i \
    HOME="$T/home" PATH="$PATH" TERM=dumb \
    GIT_CONFIG_GLOBAL="$T/gc" GIT_CONFIG_SYSTEM=/dev/null \
    XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/home/.cache" \
    REC_UPDATE_CHECK=never \
    "$1" $2 -i -c ". '$T/inst/rec-shell.sh'; $3"
}

@test "bash: rec update checks out the newest tag" {
  up_in bash --norc "rec update >/dev/null 2>&1; cat '$T/inst/VERSION'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0.0.2"* ]]
}

@test "zsh: rec update checks out the newest tag" {
  up_in zsh -f "rec update >/dev/null 2>&1; cat '$T/inst/VERSION'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0.0.2"* ]]
}

@test "bash: rec update reports already up to date on the newest tag" {
  git -C "$T/inst" checkout -q v0.0.2
  up_in bash --norc 'rec update 2>&1'
  [[ "$output" == *"up to date"* ]]
}

@test "zsh: rec update reports already up to date on the newest tag" {
  git -C "$T/inst" checkout -q v0.0.2
  up_in zsh -f 'rec update 2>&1'
  [[ "$output" == *"up to date"* ]]
}
