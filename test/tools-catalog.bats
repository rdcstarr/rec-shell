#!/usr/bin/env bats
#
# Tests for lib/tools-catalog.sh.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CAT="$REPO_ROOT/lib/tools-catalog.sh"
  T="$(mktemp -d)"
  mkdir -p "$T/bin"
}
teardown() { rm -rf "$T"; }

# Source the catalog (and its core/ui deps) in a sandboxed shell.
cat_in() {
  local shell="$1"
  shift
  run "$shell" -c "
    export HOME='$T' PATH='$T/bin:/usr/bin:/bin' REC_SHELL_DIR='$REPO_ROOT'
    REC_SHELL_NAME='$shell' REC_UI_PLAIN=1
    . '$REPO_ROOT/lib/core.sh'
    . '$REPO_ROOT/lib/ui.sh'
    . '$CAT'
    $*"
}

@test "rec_tools_catalog emits one pipe-separated record per known tool" {
  cat_in bash 'rec_tools_catalog | wc -l | awk "{print \$1}"'
  [ "$status" -eq 0 ]
  # Catalog must include at least the 12 declared tools.
  [ "$output" -ge 12 ]
}

@test "rec_tools_catalog records are well-formed (5 fields each)" {
  cat_in bash 'rec_tools_catalog | awk -F"|" "NF != 5 { print \"bad:\" \$0; exit 1 } END { print \"ok\" }"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "rec_tools_present returns 0 when the binary is on PATH" {
  printf "#!/bin/sh\nexit 0\n" >"$T/bin/eza"
  chmod +x "$T/bin/eza"
  cat_in bash 'rec_tools_present eza && echo Y || echo N'
  [[ "$output" == "Y" ]]
}

@test "rec_tools_present returns 1 when the binary is absent" {
  cat_in bash '
    rec_have() { case "$1" in eza) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
    rec_tools_present eza && echo Y || echo N'
  [[ "$output" == "N" ]]
}

@test "rec_tools_present checks the plugin file for zsh-plugin entries" {
  # zsh-autosuggestions is "present" iff its main file is readable under
  # $REC_SHELL_DIR/plugins/<name>/<name>.zsh.
  cat_in bash 'rec_tools_present zsh-autosuggestions && echo Y || echo N'
  # In this test we point REC_SHELL_DIR at the dev repo, which does not ship
  # the plugin checkout -> expect "N".
  [[ "$output" == "N" ]]
}

@test "rec_tools_missing skips installed tools, lists the rest" {
  # Stub two tools as present; the rest stay missing.
  printf "#!/bin/sh\nexit 0\n" >"$T/bin/eza"
  printf "#!/bin/sh\nexit 0\n" >"$T/bin/bat"
  chmod +x "$T/bin/eza" "$T/bin/bat"
  cat_in bash 'rec_tools_missing | sort | tr "\n" " "'
  [ "$status" -eq 0 ]
  [[ "$output" != *"eza"* ]]
  [[ "$output" != *"bat"* ]]
  [[ "$output" == *"fd"* ]]
}

@test "rec_tools_count_missing returns an integer" {
  cat_in bash 'rec_tools_count_missing'
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
}
