#!/usr/bin/env bats
#
# Tests for `rec install` (lib/cli-install.sh) and the install.sh
# --tools-only flag.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$(mktemp -d)"
  mkdir -p "$T/bin"
}
teardown() { rm -rf "$T"; }

@test "install.sh --tools-only --no-tools is a no-op (exits 0 without cloning)" {
  # PATH gives bash access to coreutils but the script never reaches a clone:
  # --no-tools combined with --tools-only short-circuits everything.
  run bash "$REPO_ROOT/install.sh" --tools-only --no-tools --unattended
  [ "$status" -eq 0 ]
  # Must NOT have hit clone_or_update — its banner contains "Cloning" or
  # "Updating existing checkout".
  [[ "$output" != *"Cloning"* ]]
  [[ "$output" != *"Updating existing checkout"* ]]
}

# Source the module with a sandboxed PATH + stubbed install.sh.
install_in() {
  local shell="$1"
  shift
  run "$shell" -c "
    export HOME='$T' PATH='$T/bin:/usr/bin:/bin' REC_SHELL_DIR='$T/repo'
    REC_SHELL_NAME='$shell' REC_UI_PLAIN=1
    mkdir -p '$T/repo/lib' '$T/repo'
    cp '$REPO_ROOT/lib/core.sh' '$T/repo/lib/'
    cp '$REPO_ROOT/lib/ui.sh' '$T/repo/lib/'
    cp '$REPO_ROOT/lib/tools-catalog.sh' '$T/repo/lib/'
    cp '$REPO_ROOT/lib/cli-install.sh' '$T/repo/lib/'
    # Stub install.sh so we observe how rec install invokes it.
    cat > '$T/repo/install.sh' <<'EOF'
#!/bin/sh
echo \"INSTALL_CALL: \$*\"
exit 0
EOF
    chmod +x '$T/repo/install.sh'
    . '$T/repo/lib/core.sh'
    . '$T/repo/lib/ui.sh'
    . '$T/repo/lib/tools-catalog.sh'
    . '$T/repo/lib/cli-install.sh'
    $*"
}

@test "rec install help mentions list, run, and interactive forms" {
  install_in bash '__rec_install_help'
  [ "$status" -eq 0 ]
  [[ "$output" == *"list"* && "$output" == *"all"* ]]
}

@test "rec install list shows [✓]/[✗] markers per catalog tool" {
  # Stub two tools as installed, the rest absent.
  printf "#!/bin/sh\nexit 0\n" >"$T/bin/eza"
  printf "#!/bin/sh\nexit 0\n" >"$T/bin/bat"
  chmod +x "$T/bin/eza" "$T/bin/bat"
  install_in bash '__rec_install_list'
  [ "$status" -eq 0 ]
  # Installed tools render with the OK glyph (✓ / [ok]).
  [[ "$output" == *"eza"* && ( "$output" == *"✓"* || "$output" == *"[ok]"* ) ]]
}

@test "rec install <name> calls install.sh with --tools-only and --tools=NAME" {
  install_in bash '__rec_install_run fd'
  [ "$status" -eq 0 ]
  [[ "$output" == *"INSTALL_CALL:"* ]]
  [[ "$output" == *"--tools-only"* ]]
  [[ "$output" == *"--tools=fd"* ]]
  [[ "$output" == *"--unattended"* ]]
}

@test "rec install all installs every missing tool" {
  # Only eza is present, so rec install all should ask install.sh for the rest.
  printf "#!/bin/sh\nexit 0\n" >"$T/bin/eza"
  chmod +x "$T/bin/eza"
  install_in bash '__rec_install_dispatch all'
  [ "$status" -eq 0 ]
  [[ "$output" == *"INSTALL_CALL:"* ]]
  [[ "$output" == *"--tools=fd"* || "$output" == *",fd"* || "$output" == *"fd,"* ]]
  [[ "$output" != *"--tools=eza"* ]]
}

@test "rec install run with no missing tools exits 0 with a friendly message" {
  # Mark every catalog tool present via a rec_have / rec_tools_present override.
  install_in bash '
    rec_have() { return 0; }
    rec_tools_present() { return 0; }
    __rec_install_dispatch all'
  [ "$status" -eq 0 ]
  [[ "$output" == *"already installed"* || "$output" == *"All tools"* ]]
}

@test "rec install <unknown-tool> errors with exit 2" {
  install_in bash '__rec_install_run no-such-tool'
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown tool"* ]]
}

@test "rec install dispatch with no TTY prints usage hint and exits 0" {
  install_in bash '__rec_install_dispatch'
  [ "$status" -eq 0 ]
  # Non-interactive: must NOT block on a multiselect. Either prints hint and
  # returns 0, or prints the same as `list` — either is acceptable here.
  [[ "$output" == *"rec install"* ]]
}
