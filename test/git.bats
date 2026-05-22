#!/usr/bin/env bats
#
# Tests for the `rec git` command group (lib/cli-git.sh), exercised in bash and
# zsh against real local git repos (a bare "origin" plus a working clone).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$(mktemp -d)"
  export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
  git config -f "$T/gitconfig" user.email t@example.com
  git config -f "$T/gitconfig" user.name tester
  git config -f "$T/gitconfig" init.defaultBranch main
  git config -f "$T/gitconfig" advice.detachedHead false

  git init -q --bare "$T/origin.git"
  git clone -q "$T/origin.git" "$T/work" 2>/dev/null
  (cd "$T/work" && echo one >f.txt && git add -A && git commit -qm one && git push -q -u origin main)
  # advance origin by one commit from a second clone -> work is now 1 behind
  git clone -q "$T/origin.git" "$T/other" 2>/dev/null
  (cd "$T/other" && echo two >>f.txt && git commit -qam two && git push -q origin main)
}

teardown() {
  rm -rf "$T"
}

# git_in SHELL DIR CODE
git_in() {
  local shell="$1" dir="$2"
  shift 2
  run "$shell" -c "cd '$dir'; . '$REPO_ROOT/lib/cli-git.sh'; $*"
}

# --- sync: fast-forward ----------------------------------------------------

@test "bash: git sync fast-forwards a clean repo that is behind" {
  git_in bash "$T/work" '__rec_git_sync'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Updated"* ]]
  grep -q two "$T/work/f.txt"
}

@test "zsh: git sync fast-forwards a clean repo that is behind" {
  git_in zsh "$T/work" '__rec_git_sync'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Updated"* ]]
  grep -q two "$T/work/f.txt"
}

@test "bash: git sync reports up to date when current" {
  (cd "$T/work" && git fetch -q origin && git merge -q --ff-only origin/main)
  git_in bash "$T/work" '__rec_git_sync'
  [ "$status" -eq 0 ]
  [[ "$output" == *"up to date"* ]]
}

# --- sync: dirty tree ------------------------------------------------------

@test "bash: git sync refuses when the tree is dirty" {
  echo dirty >>"$T/work/f.txt"
  git_in bash "$T/work" '__rec_git_sync'
  [ "$status" -ne 0 ]
  [[ "$output" == *"uncommitted"* ]]
  grep -q dirty "$T/work/f.txt" # untouched
}

@test "bash: git sync --force hard-resets a dirty repo to origin" {
  echo dirty >>"$T/work/f.txt"
  git_in bash "$T/work" '__rec_git_sync --force'
  [ "$status" -eq 0 ]
  grep -q two "$T/work/f.txt"
  ! grep -q dirty "$T/work/f.txt"
}

# --- sync: error handling --------------------------------------------------

@test "bash: git sync errors outside a git repo" {
  git_in bash "$T" '__rec_git_sync'
  [ "$status" -ne 0 ]
}

# --- ported helpers still work (incl. zsh, where IFS-read + regex matter) ---

@test "bash: git release --dry-run computes a tag without pushing" {
  git_in bash "$T/work" '__rec_git_release --dry-run'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Next tag: v"* ]]
}

@test "zsh: git release --dry-run computes a tag without pushing" {
  git_in zsh "$T/work" '__rec_git_release --dry-run'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Next tag: v"* ]]
}

@test "zsh: git push --dry-run runs on a clean repo" {
  (cd "$T/work" && git fetch -q origin && git merge -q --ff-only origin/main)
  git_in zsh "$T/work" '__rec_git_push --dry-run'
  [ "$status" -eq 0 ]
}
