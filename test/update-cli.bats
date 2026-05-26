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

@test "bash: rec update appends 'rec install' nudge when catalog tools are missing" {
  # Reuse the setup() fixture: $T/inst is at v0.0.1, $T/origin.git has v0.0.2.
  # Use a sanitized PATH and override rec_have so every catalog tool reads
  # as missing — this makes the assertion deterministic across mac/linux.
  run env -i \
    HOME="$T/home" PATH="/usr/bin:/bin" TERM=dumb \
    GIT_CONFIG_GLOBAL="$T/gc" GIT_CONFIG_SYSTEM=/dev/null \
    XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/home/.cache" \
    REC_UPDATE_CHECK=never \
    bash --norc -i -c "
      . '$T/inst/rec-shell.sh'
      rec_have() {
        case \$1 in
          fzf|atuin|eza|bat|fd|fdfind|rg|batcat|btop|ncdu|whois|dig) return 1 ;;
          *) command -v \$1 >/dev/null 2>&1 ;;
        esac
      }
      rec update 2>&1"
  [ "$status" -eq 0 ]
  # The nudge text from __rec_cmd_update (the exact wording from the plan).
  [[ "$output" == *"rec install"* ]]
  [[ "$output" == *"modern CLI tools available"* ]]
}

@test "bash: rec update on the newest tag stays quiet (no nudge on no-op)" {
  # When there's nothing to update, the function returns early before the
  # banner + nudge — the existing 'already up to date' message is the only
  # thing the user sees.
  git -C "$T/inst" checkout -q v0.0.2
  run env -i \
    HOME="$T/home" PATH="/usr/bin:/bin" TERM=dumb \
    GIT_CONFIG_GLOBAL="$T/gc" GIT_CONFIG_SYSTEM=/dev/null \
    XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/home/.cache" \
    REC_UPDATE_CHECK=never \
    bash --norc -i -c "
      . '$T/inst/rec-shell.sh'
      rec_have() {
        case \$1 in
          fzf|atuin|eza|bat|fd|fdfind|rg|batcat|btop|ncdu|whois|dig) return 1 ;;
          *) command -v \$1 >/dev/null 2>&1 ;;
        esac
      }
      rec update 2>&1"
  [[ "$output" == *"up to date"* ]]
  [[ "$output" != *"rec install"* ]]
}
