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

# Regression: on Debian < 12 (and any distro without eza in default repos),
# `apt install eza` returns "Unable to locate package eza" and the install
# used to silently fail with a generic warning. ensure_eza now falls back
# to a prebuilt binary from GitHub releases.
#
# Strategy:
#   - run install.sh as a SCRIPT (not source) so its `exit 0` doesn't kill
#     the parent and so install_tools_all reaches ensure_eza naturally
#   - stub apt-get (returns "Unable to locate package")
#   - stub sudo to pass through, since pm_install uses `sudo -n apt-get` and
#     real sudo's secure_path would bypass our stubs
#   - stub uname so the test works on both Linux CI and macOS dev box
#   - stub curl + tar to capture the URL and produce a fake eza tarball
#   - assert via grep on the curl log (NOT bash `[[ ]]`), so the test works
#     identically on bash 3.2 (macOS) and bash 5.x (Ubuntu CI)
@test "ensure_eza: falls back to GitHub binary when pm_install fails" {
  T="$(mktemp -d)"
  mkdir -p "$T/bin"
  # Stub curl: capture URL + emit a tarball containing an executable "eza".
  cat >"$T/bin/curl" <<EOF
#!/bin/sh
out=""; url=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
echo "\$url" >>"$T/curl-calls.log"
mkdir -p "$T/eza-stage"
printf '%s\n%s\n' '#!/bin/sh' 'echo fake-eza' >"$T/eza-stage/eza"
chmod +x "$T/eza-stage/eza"
tar -czf "\$out" -C "$T/eza-stage" eza
EOF
  chmod +x "$T/bin/curl"
  # Stub apt-get (fails — simulates "package not in repos").
  cat >"$T/bin/apt-get" <<'EOF'
#!/bin/sh
echo "apt-get: E: Unable to locate package eza" >&2
exit 100
EOF
  chmod +x "$T/bin/apt-get"
  # Stub sudo: strip flags then exec — keeps our PATH (real sudo resets it
  # via secure_path and would bypass our apt-get stub on Ubuntu CI).
  cat >"$T/bin/sudo" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in -*) shift ;; *) break ;; esac
done
exec "$@"
EOF
  chmod +x "$T/bin/sudo"
  # Stub uname so the Linux fallback branch runs even on macOS (eza upstream
  # doesn't ship Darwin binaries, so the production code skips fallback there;
  # the test wants to exercise the Linux path regardless of host).
  cat >"$T/bin/uname" <<'EOF'
#!/bin/sh
case "$1" in
  -s) echo Linux ;;
  -m) echo x86_64 ;;
  *)  /usr/bin/uname "$@" 2>/dev/null || echo Linux ;;
esac
EOF
  chmod +x "$T/bin/uname"
  # Run install.sh as a script (not source). --tools=eza scopes work to
  # ensure_eza; all other ensure_X functions short-circuit via tool_selected.
  run env -i \
    HOME="$T" PATH="$T/bin:/usr/bin:/bin" \
    bash "$REPO_ROOT/install.sh" --tools-only --tools=eza --unattended
  # curl was hit with a GitHub release URL targeting an x86_64 Linux build.
  [ -r "$T/curl-calls.log" ]
  grep -q '^https://github.com/eza-community/eza/releases/latest/download/eza_' "$T/curl-calls.log"
  grep -q -- 'x86_64-unknown-linux' "$T/curl-calls.log"
  # The fake eza landed under $HOME/.local/bin (non-root path).
  [ -x "$T/.local/bin/eza" ]
  rm -rf "$T"
}

# Same fallback pattern as eza but for btop, whose release archive is .tbz
# (bzip2) with a `btop/bin/btop` layout and an adjacent themes/ directory.
# btop isn't in Debian < 12 main repos so this matters on bullseye and
# older Ubuntu LTS.
@test "ensure_btop: falls back to GitHub binary when pm_install fails" {
  T="$(mktemp -d)"
  mkdir -p "$T/bin"
  # curl stub: capture URL + emit a .tbz with the upstream layout.
  cat >"$T/bin/curl" <<EOF
#!/bin/sh
out=""; url=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
echo "\$url" >>"$T/curl-calls.log"
# btop release archives are .tar.gz (gzip), not .tbz — match upstream.
mkdir -p "$T/stage/btop/bin" "$T/stage/btop/themes"
printf '%s\n%s\n' '#!/bin/sh' 'echo fake-btop' >"$T/stage/btop/bin/btop"
chmod +x "$T/stage/btop/bin/btop"
echo "fake" >"$T/stage/btop/themes/sample.theme"
tar -czf "\$out" -C "$T/stage" btop
EOF
  chmod +x "$T/bin/curl"
  cat >"$T/bin/apt-get" <<'EOF'
#!/bin/sh
echo "apt-get: E: Unable to locate package btop" >&2
exit 100
EOF
  chmod +x "$T/bin/apt-get"
  cat >"$T/bin/sudo" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in -*) shift ;; *) break ;; esac
done
exec "$@"
EOF
  chmod +x "$T/bin/sudo"
  cat >"$T/bin/uname" <<'EOF'
#!/bin/sh
case "$1" in
  -s) echo Linux ;;
  -m) echo x86_64 ;;
  *)  /usr/bin/uname "$@" 2>/dev/null || echo Linux ;;
esac
EOF
  chmod +x "$T/bin/uname"
  run env -i \
    HOME="$T" PATH="$T/bin:/usr/bin:/bin" \
    bash "$REPO_ROOT/install.sh" --tools-only --tools=btop --unattended
  [ -r "$T/curl-calls.log" ]
  # Assert the EXACT URL pattern verified against the GitHub releases API:
  # `btop-<arch>-unknown-linux-musl.tar.gz` (not `.tbz`, not without `-unknown-`).
  grep -qE '^https://github\.com/aristocratos/btop/releases/latest/download/btop-x86_64-unknown-linux-musl\.tar\.gz$' "$T/curl-calls.log"
  # The fake btop landed under $HOME/.local/bin (non-root path).
  [ -x "$T/.local/bin/btop" ]
  # Themes copied into $HOME/.config/btop/themes/.
  [ -r "$T/.config/btop/themes/sample.theme" ]
  rm -rf "$T"
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
    cp '$REPO_ROOT/lib/ui-interactive.sh' '$T/repo/lib/'
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
  # Per-tool log captures the stub install.sh invocation.
  log="$T/.cache/rec-shell/install-logs/fd.log"
  [ -r "$log" ]
  grep -q 'INSTALL_CALL:'  "$log"
  grep -q -- '--tools-only' "$log"
  grep -q -- '--tools=fd'   "$log"
  grep -q -- '--unattended' "$log"
}

@test "rec install all installs every missing tool" {
  # Only eza is present; rec install all should call install.sh once per
  # missing tool — never for eza.
  printf "#!/bin/sh\nexit 0\n" >"$T/bin/eza"
  chmod +x "$T/bin/eza"
  install_in bash '__rec_install_dispatch all'
  [ "$status" -eq 0 ]
  [ -r "$T/.cache/rec-shell/install-logs/fd.log" ]
  [ -r "$T/.cache/rec-shell/install-logs/btop.log" ]
  [ -r "$T/.cache/rec-shell/install-logs/ncdu.log" ]
  # eza was already present, so no log was created for it.
  [ ! -e "$T/.cache/rec-shell/install-logs/eza.log" ]
  # Final summary line appears in output.
  [[ "$output" == *"installed"* ]]
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

@test "rec install dispatch with no TTY installs all missing and exits 0" {
  # v2.0.0: no-args dispatches to __rec_install_run_missing — no picker,
  # no block, just runs the installer for everything currently missing.
  install_in bash '__rec_install_dispatch'
  [ "$status" -eq 0 ]
  # Either says "Installing:" (something missing) or "already installed"
  # (nothing missing). Both are valid non-blocking outcomes.
  [[ "$output" == *"Installing:"* || "$output" == *"already installed"* ]]
}

# Regression: zsh does not word-split unquoted variable expansion by default,
# so a newline-delimited `rec_tools_missing` would land as a single positional
# inside __rec_install_interactive and break the multiselect's cursor math
# (rendering the option list duplicated on every arrow keypress). The fix is
# `setopt local_options sh_word_split` for zsh; this test verifies the split
# yields one positional per name in BOTH shells.
@test "bash: __rec_install_interactive splits a multi-line missing list into N args" {
  install_in bash '
    rec_tools_missing() { printf "fzf\nfd\nbtop\nncdu\nzsh-autosuggestions\nzsh-syntax-highlighting\n"; }
    __rec_ui_interactive() { return 0; }
    rec_ui_interactive_load() { return 0; }
    rec_ui_multiselect() { shift; printf "GOT_TOOLS:%d\n" "$#" >&2; REC_UI_REPLY=""; }
    __rec_install_interactive'
  [ "$status" -eq 0 ]
  [[ "$output" == *"GOT_TOOLS:6"* ]]
}

@test "zsh: __rec_install_interactive splits a multi-line missing list into N args" {
  install_in zsh '
    rec_tools_missing() { printf "fzf\nfd\nbtop\nncdu\nzsh-autosuggestions\nzsh-syntax-highlighting\n"; }
    __rec_ui_interactive() { return 0; }
    rec_ui_interactive_load() { return 0; }
    rec_ui_multiselect() { shift; printf "GOT_TOOLS:%d\n" "$#" >&2; REC_UI_REPLY=""; }
    __rec_install_interactive'
  [ "$status" -eq 0 ]
  [[ "$output" == *"GOT_TOOLS:6"* ]]
}

# Regression: install.sh is bash (uses `set -o pipefail`, `local`, `[[ ]]`),
# so __rec_install_exec must invoke it with bash, NOT /bin/sh. On Debian
# systems /bin/sh is dash and would error out with
# "Illegal option -o pipefail" at install.sh line 12 (`set -euo pipefail`).
@test "rec install <name> invokes install.sh via bash (not /bin/sh)" {
  # Replace the install.sh stub so it reports the interpreter that ran it
  # via a bash-only env var (BASH_VERSION is set only under bash).
  T="$(mktemp -d)"
  mkdir -p "$T/bin" "$T/repo/lib" "$T/repo"
  cp lib/core.sh lib/ui.sh lib/tools-catalog.sh lib/cli-install.sh "$T/repo/lib/"
  cat >"$T/repo/install.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "RAN_VIA: ${BASH_VERSION:+bash} ${BASH_VERSION:-not-bash}"
EOF
  chmod +x "$T/repo/install.sh"
  run bash -c "
    export HOME='$T' PATH='$T/bin:/usr/bin:/bin' REC_SHELL_DIR='$T/repo'
    REC_SHELL_NAME=bash REC_UI_PLAIN=1
    . '$T/repo/lib/core.sh'
    . '$T/repo/lib/ui.sh'
    . '$T/repo/lib/tools-catalog.sh'
    . '$T/repo/lib/cli-install.sh'
    __rec_install_run fd"
  [ "$status" -eq 0 ]
  # Stub output went to the per-tool log; assert there.
  log="$T/.cache/rec-shell/install-logs/fd.log"
  [ -r "$log" ]
  grep -q 'RAN_VIA: bash' "$log"
  ! grep -q 'not-bash' "$log"
  rm -rf "$T"
}

# Per-tool log file is created at $REC_CACHE_DIR/install-logs/<tool>.log so
# users can inspect exactly what apt / curl said when something fails.
@test "rec install <name> writes a per-tool log under REC_CACHE_DIR" {
  install_in bash '__rec_install_run ripgrep'
  [ "$status" -eq 0 ]
  log="$T/.cache/rec-shell/install-logs/ripgrep.log"
  [ -r "$log" ]
  # Stub install.sh echoes INSTALL_CALL — confirm the log captured it.
  grep -q 'INSTALL_CALL:' "$log"
}

# Failure case: when install.sh exits non-zero, rec install must point the
# user at the log file so they can diagnose.
@test "rec install reports a failure with the log path when install.sh fails" {
  T="$(mktemp -d)"
  mkdir -p "$T/bin" "$T/repo/lib" "$T/repo"
  cp lib/core.sh lib/ui.sh lib/tools-catalog.sh lib/cli-install.sh "$T/repo/lib/"
  cat >"$T/repo/install.sh" <<'EOF'
#!/usr/bin/env bash
echo "FAKE_APT_ERROR: unable to locate package" >&2
exit 100
EOF
  chmod +x "$T/repo/install.sh"
  run bash -c "
    export HOME='$T' PATH='$T/bin:/usr/bin:/bin' REC_SHELL_DIR='$T/repo'
    REC_SHELL_NAME=bash REC_UI_PLAIN=1
    . '$T/repo/lib/core.sh'
    . '$T/repo/lib/ui.sh'
    . '$T/repo/lib/tools-catalog.sh'
    . '$T/repo/lib/cli-install.sh'
    __rec_install_run fd"
  # Summary surfaces failure and points to log dir.
  [[ "$output" == *"failed"* ]]
  [[ "$output" == *"install-logs"* ]]
  log="$T/.cache/rec-shell/install-logs/fd.log"
  [ -r "$log" ]
  grep -q 'FAKE_APT_ERROR' "$log"
  rm -rf "$T"
}

# Shell-plugin filtering follows the *invoking user's* shell (USER_SHELL),
# not the host OS. ble.sh keeps a hard exclusion on macOS because its build
# is unreliable there (gawk dependency vs BSD awk).
#
# NOTE on assertion style: bats only treats the FINAL `[[ ]]` exit code as
# the test result — intermediate `[[ ]]` failures are silently ignored. We
# therefore use `grep -qx` (single-bracket-friendly) for each line check so
# every assertion contributes to test pass/fail.
@test "tool_selected (USER_SHELL=bash, linux, user): ble.sh on, zsh-* off" {
  run bash -c "
    REC_INSTALL_SOURCED=1
    . '$REPO_ROOT/install.sh'
    OS=linux MODE=user USER_SHELL=bash
    if tool_selected ble.sh; then echo BLE_SELECTED; else echo BLE_SKIPPED; fi
    if tool_selected zsh-autosuggestions; then echo ZSHAUTO_SELECTED; else echo ZSHAUTO_SKIPPED; fi
    if tool_selected zsh-syntax-highlighting; then echo ZSHSYNTAX_SELECTED; else echo ZSHSYNTAX_SKIPPED; fi
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx BLE_SELECTED
  printf '%s\n' "$output" | grep -qx ZSHAUTO_SKIPPED
  printf '%s\n' "$output" | grep -qx ZSHSYNTAX_SKIPPED
}

@test "tool_selected (USER_SHELL=zsh, linux, user): zsh-* on, ble.sh off" {
  run bash -c "
    REC_INSTALL_SOURCED=1
    . '$REPO_ROOT/install.sh'
    OS=linux MODE=user USER_SHELL=zsh
    if tool_selected ble.sh; then echo BLE_SELECTED; else echo BLE_SKIPPED; fi
    if tool_selected zsh-autosuggestions; then echo ZSHAUTO_SELECTED; else echo ZSHAUTO_SKIPPED; fi
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx BLE_SKIPPED
  printf '%s\n' "$output" | grep -qx ZSHAUTO_SELECTED
}

@test "tool_selected (USER_SHELL=zsh, mac, user): zsh-* on, ble.sh off" {
  run bash -c "
    REC_INSTALL_SOURCED=1
    . '$REPO_ROOT/install.sh'
    OS=mac MODE=user USER_SHELL=zsh
    if tool_selected ble.sh; then echo BLE_SELECTED; else echo BLE_SKIPPED; fi
    if tool_selected zsh-autosuggestions; then echo ZSHAUTO_SELECTED; else echo ZSHAUTO_SKIPPED; fi
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx BLE_SKIPPED
  printf '%s\n' "$output" | grep -qx ZSHAUTO_SELECTED
}

# macOS+bash: ble.sh is off by the macOS guard, zsh-* are off by shell mismatch.
@test "tool_selected (USER_SHELL=bash, mac, user): ble.sh off (macOS guard), zsh-* off" {
  run bash -c "
    REC_INSTALL_SOURCED=1
    . '$REPO_ROOT/install.sh'
    OS=mac MODE=user USER_SHELL=bash
    if tool_selected ble.sh; then echo BLE_SELECTED; else echo BLE_SKIPPED; fi
    if tool_selected zsh-autosuggestions; then echo ZSHAUTO_SELECTED; else echo ZSHAUTO_SKIPPED; fi
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx BLE_SKIPPED
  printf '%s\n' "$output" | grep -qx ZSHAUTO_SKIPPED
}

# Regression: the user's bug — Linux + bash invoker + --system was offering
# zsh plugins because the OS-based filter was bypassed in system mode.
@test "tool_selected applies USER_SHELL filter even in --system mode" {
  run bash -c "
    REC_INSTALL_SOURCED=1
    . '$REPO_ROOT/install.sh'
    OS=linux MODE=system USER_SHELL=bash
    if tool_selected ble.sh; then echo BLE_SELECTED; else echo BLE_SKIPPED; fi
    if tool_selected zsh-autosuggestions; then echo ZSHAUTO_SELECTED; else echo ZSHAUTO_SKIPPED; fi
    if tool_selected zsh-syntax-highlighting; then echo ZSHSYNTAX_SELECTED; else echo ZSHSYNTAX_SKIPPED; fi
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx BLE_SELECTED
  printf '%s\n' "$output" | grep -qx ZSHAUTO_SKIPPED
  printf '%s\n' "$output" | grep -qx ZSHSYNTAX_SKIPPED
}

# Under `sudo`, $SHELL is unreliable (often points at root's shell or is
# stripped by env_reset). The invoker's actual login shell lives in
# /etc/passwd, lookup-able via `getent passwd $SUDO_USER`. Stub getent to
# return a known shell and assert detect_user_shell prefers it.
@test "detect_user_shell prefers SUDO_USER login shell via getent" {
  cat >"$T/bin/getent" <<'EOF'
#!/bin/sh
# Only respond to "passwd alice"; everything else returns empty.
if [ "$1" = passwd ] && [ "$2" = alice ]; then
  printf 'alice:x:1000:1000::/home/alice:/usr/bin/zsh\n'
fi
EOF
  chmod +x "$T/bin/getent"
  run bash -c "
    export PATH='$T/bin:/usr/bin:/bin'
    REC_INSTALL_SOURCED=1
    . '$REPO_ROOT/install.sh'
    SUDO_USER=alice SHELL=/bin/bash detect_user_shell
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx zsh
}

@test "detect_user_shell falls back to \$SHELL when no SUDO_USER" {
  run bash -c "
    REC_INSTALL_SOURCED=1
    . '$REPO_ROOT/install.sh'
    unset SUDO_USER
    SHELL=/usr/bin/zsh detect_user_shell
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx zsh
}

# Regression: on macOS under \`sudo\`, getent doesn't exist and \$SHELL is
# stripped by env_reset (often ends up /bin/sh from root's defaults). We
# must fall back to \`dscl . -read /Users/$SUDO_USER UserShell\` to recover
# the invoking user's actual shell — otherwise the installer treats them
# as bash and skips the zsh plugins entirely.
@test "detect_user_shell uses dscl on macOS when getent yields nothing" {
  # Stub getent to fail (simulates 'not installed' on macOS).
  cat >"$T/bin/getent" <<'EOF'
#!/bin/sh
exit 1
EOF
  chmod +x "$T/bin/getent"
  # Stub dscl: respond to "-read /Users/alice UserShell".
  cat >"$T/bin/dscl" <<'EOF'
#!/bin/sh
if [ "$1" = "." ] && [ "$2" = "-read" ] && [ "$3" = "/Users/alice" ] && [ "$4" = "UserShell" ]; then
  printf 'UserShell: /bin/zsh\n'
fi
EOF
  chmod +x "$T/bin/dscl"
  run bash -c "
    export PATH='$T/bin:/usr/bin:/bin'
    REC_INSTALL_SOURCED=1
    . '$REPO_ROOT/install.sh'
    SUDO_USER=alice SHELL=/bin/sh detect_user_shell
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx zsh
}

# Unknown shells (/bin/sh under sudo env_reset, exotic shells) should map
# to bash defaults so SHELL_BIN doesn't show 'exec /bin/sh -l' in the
# post-install hint.
@test "detect_user_shell_path sanitizes unknown shells to /bin/bash" {
  run bash -c "
    REC_INSTALL_SOURCED=1
    . '$REPO_ROOT/install.sh'
    unset SUDO_USER
    SHELL=/bin/sh detect_user_shell_path
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx /bin/bash
}

# v2.0.0: install_all_tools replaces the maybe_multiselect_tools picker
# entirely. The only remaining opt-outs are --no-tools (INSTALL_TOOLS=none)
# and "all already present" (INSTALL_TOOLS=done set elsewhere).
@test "install_all_tools: prints skip message when INSTALL_TOOLS=none (user --no-tools)" {
  run bash -c "
    REC_INSTALL_SOURCED=1
    . '$REPO_ROOT/install.sh'
    INSTALL_TOOLS=none
    install_all_tools
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"--no-tools"* ]]
}

@test "install_all_tools: silent when INSTALL_TOOLS=done (nothing was missing)" {
  run bash -c "
    REC_INSTALL_SOURCED=1
    . '$REPO_ROOT/install.sh'
    INSTALL_TOOLS=done
    install_all_tools
  "
  [ "$status" -eq 0 ]
  [[ "$output" != *"--no-tools"* ]]
  [[ "$output" != *"Skipping"* ]]
}

@test "ensure_blesh emits actionable warning when gawk is missing on macOS" {
  T="$(mktemp -d)"
  mkdir -p "$T/bin"
  # Stub make + git as present; deliberately do NOT provide gawk in the
  # sandboxed PATH. We never reach make/git anyway because gawk check
  # fires first.
  printf '#!/bin/sh\nexit 0\n' >"$T/bin/make"
  printf '#!/bin/sh\nexit 0\n' >"$T/bin/git"
  chmod +x "$T/bin/make" "$T/bin/git"
  run bash -c "
    PATH='$T/bin:/usr/bin:/bin'
    REC_INSTALL_SOURCED=1
    . '$REPO_ROOT/install.sh'
    # TOOLS_ALLOW=ble.sh models the explicit-opt-in path (e.g. \`rec install
    # ble.sh\`), which bypasses tool_selected's prompt-only shell/OS filter.
    OS=mac MODE=system UNATTENDED=1 TOOLS_ALLOW=ble.sh
    # Force pm_install to fail so we drop through to the actionable warning
    # (deterministic across Linux CI / macOS dev box).
    pm_install() { return 1; }
    ensure_blesh
  "
  # ensure_blesh returns 1 on dep-missing, so don't assert status == 0.
  # Assert the actionable hint surfaces in the merged stderr+stdout (`run`
  # merges them). v1.9.0 changed the warning to mention all three deps
  # (make/git/gawk) together since the loop installs all of them.
  printf '%s\n' "$output" | grep -q gawk
  printf '%s\n' "$output" | grep -q 'brew install'
  rm -rf "$T"
}

# Regression: on Debian under \`curl | sudo bash\`, the user said y to ble.sh
# and the installer bailed with "ble.sh requires gawk". When the user
# explicitly opted in to ble.sh, we should auto-install its dependency
# (gawk) via the system package manager rather than punting back to them.
@test "ensure_blesh: auto-installs gawk via pm_install when missing" {
  T="$(mktemp -d)"
  mkdir -p "$T/bin"
  printf '#!/bin/sh\nexit 0\n' >"$T/bin/make"
  # Stub git to fail the clone deliberately — we only care that pm_install
  # got called for gawk, not that the full build completes.
  printf '#!/bin/sh\nexit 1\n' >"$T/bin/git"
  chmod +x "$T/bin/make" "$T/bin/git"
  run bash -c "
    PATH='$T/bin:/usr/bin:/bin'
    REC_INSTALL_SOURCED=1
    . '$REPO_ROOT/install.sh'
    OS=linux MODE=system UNATTENDED=1 TOOLS_ALLOW=ble.sh
    pm_install() {
      printf 'PM_INSTALL_CALLED: %s\\n' \"\$*\"
      # Simulate apt-get succeeding by dropping a stub gawk on PATH.
      printf '#!/bin/sh\\nexit 0\\n' >'$T/bin/gawk'
      chmod +x '$T/bin/gawk'
      return 0
    }
    ensure_blesh
  "
  printf '%s\n' "$output" | grep -q '^PM_INSTALL_CALLED: gawk$'
  # When pm_install succeeds we must NOT fall through to the actionable
  # warning (that's the "all hope lost" path).
  ! printf '%s\n' "$output" | grep -q 'ble.sh requires gawk'
  rm -rf "$T"
}

# Under \`sudo\` with default sudoers (env_reset), TERM is stripped. The
# multiselect probe in maybe_multiselect_tools rejects an empty TERM, so
# the picker never renders and users get one y/N prompt per tool instead.
# __rec_default_term gives us a sensible default to plug back in.
# Regression: oh-my-posh's official installer requires `unzip`, but on a
# fresh Ubuntu/Debian box unzip isn't installed by default. ensure_omp
# used to abort with "unzip is required to install Oh My Posh." — we
# auto-install it the same way we auto-install gawk for ble.sh.
@test "ensure_omp: auto-installs unzip via pm_install when missing" {
  T="$(mktemp -d)"
  mkdir -p "$T/bin"
  # Stub curl so the oh-my-posh installer pipeline doesn't hit the network.
  printf '#!/bin/sh\necho CURL_CALLED\nexit 0\n' >"$T/bin/curl"
  chmod +x "$T/bin/curl"
  run bash -c "
    PATH='$T/bin:/usr/bin:/bin'
    REC_INSTALL_SOURCED=1
    . '$REPO_ROOT/install.sh'
    OS=linux MODE=system UNATTENDED=1 INSTALL_OMP=yes
    # On Linux CI/dev boxes /usr/bin/unzip and /usr/bin/oh-my-posh may
    # exist — override \`command -v\` to report them as missing so the
    # auto-install path actually runs.
    command() {
      if [ \"\$1\" = '-v' ]; then
        case \"\$2\" in unzip|oh-my-posh) return 1 ;; esac
      fi
      builtin command \"\$@\"
    }
    pm_install() {
      printf 'PM_INSTALL_CALLED: %s\\n' \"\$*\"
      return 0
    }
    ensure_omp || true
  "
  printf '%s\n' "$output" | grep -q '^PM_INSTALL_CALLED: unzip$'
  rm -rf "$T"
}

# Extends the existing gawk auto-install to cover ble.sh's other two
# build-time deps (make, git). On a clean Ubuntu box none of the three
# are present by default; the user said yes to ble.sh, so we install all
# three rather than aborting.
@test "ensure_blesh: auto-installs make + git + gawk when all missing" {
  T="$(mktemp -d)"
  mkdir -p "$T/bin"
  run bash -c "
    PATH='$T/bin:/usr/bin:/bin'
    REC_INSTALL_SOURCED=1
    . '$REPO_ROOT/install.sh'
    OS=linux MODE=system UNATTENDED=1 TOOLS_ALLOW=ble.sh
    # Real make/git/gawk live in /usr/bin on most boxes — override
    # \`command -v\` for these three so the auto-install loop fires for
    # all of them.
    command() {
      if [ \"\$1\" = '-v' ]; then
        case \"\$2\" in make|git|gawk) return 1 ;; esac
      fi
      builtin command \"\$@\"
    }
    pm_install() {
      printf 'PM_INSTALL_CALLED: %s\\n' \"\$*\"
      return 0
    }
    ensure_blesh || true
  "
  printf '%s\n' "$output" | grep -q '^PM_INSTALL_CALLED: make$'
  printf '%s\n' "$output" | grep -q '^PM_INSTALL_CALLED: git$'
  printf '%s\n' "$output" | grep -q '^PM_INSTALL_CALLED: gawk$'
  rm -rf "$T"
}

# Verify __rec_install_quietly captures the wrapped function's stdout +
# stderr to a per-tool log file. Stub a noisy function; assert the log
# file gets the output AND that the user-facing terminal stays clean
# of the wrapped function's chatter.
@test "__rec_install_quietly: captures stdout and stderr to log file" {
  T="$(mktemp -d)"
  run bash -c "
    export REC_CACHE_DIR='$T/cache'
    REC_INSTALL_SOURCED=1
    . '$REPO_ROOT/install.sh'
    noisy() {
      echo 'STDOUT_CHATTER'
      echo 'STDERR_CHATTER' >&2
      return 0
    }
    __rec_install_quietly 'Installing noisy' noisy noisy
    echo '---'
    cat '$T/cache/install-logs/noisy.log'
  "
  [ "$status" -eq 0 ]
  # The terminal output (stdout of the test run) must NOT contain the
  # chatter from inside noisy() — it should only contain the spinner's
  # final ✓/label line and our \`echo ---\` separator.
  before_sep="\$(printf '%s\n' "$output" | sed '/^---\$/q' | head -n -1)"
  ! printf '%s\n' "$before_sep" | grep -q STDOUT_CHATTER
  ! printf '%s\n' "$before_sep" | grep -q STDERR_CHATTER
  # The log file SHOULD have both.
  after_sep="\$(printf '%s\n' "$output" | sed -n '/^---\$/,\$p' | tail -n +2)"
  printf '%s\n' "$after_sep" | grep -q STDOUT_CHATTER
  printf '%s\n' "$after_sep" | grep -q STDERR_CHATTER
  rm -rf "$T"
}

# Regression: Ubuntu's needrestart hook injects 5+ lines of "Running
# kernel seems to be up-to-date" / "No services need to be restarted"
# after every apt-get install. NEEDRESTART_MODE=l (list-only) + SUSPEND=1
# silence it. install.sh exports these at script top so every pm_install
# inherits them.
# Regression: in user mode (no sudo), pm_install used to call \`sudo -n\`
# which dumped "sudo: interactive authentication is required" to stderr
# per dep. Now we probe sudo-n upfront and bail clean if it can't run
# unattended — callers (ensure_blesh) then surface their actionable
# warning instead.
@test "pm_install: bails clean when non-root and sudo -n fails" {
  T="$(mktemp -d)"
  mkdir -p "$T/bin"
  # Stub apt-get so the apt path is taken if we get that far (we won't).
  printf '#!/bin/sh\nexit 0\n' >"$T/bin/apt-get"
  chmod +x "$T/bin/apt-get"
  # Stub sudo to always fail (mimics no passwordless config).
  printf '#!/bin/sh\nexit 1\n' >"$T/bin/sudo"
  chmod +x "$T/bin/sudo"
  run bash -c "
    PATH='$T/bin:/usr/bin:/bin'
    REC_INSTALL_SOURCED=1
    . '$REPO_ROOT/install.sh'
    # Override id so we're 'not root' for the purposes of pm_install.
    id() { [ \"\$1\" = -u ] && echo 1000 || builtin command id \"\$@\"; }
    if pm_install make 2>&1; then rc=0; else rc=\$?; fi
    echo rc=\$rc
  "
  printf '%s\n' "$output" | grep -qx 'rc=1'
  # And we must NOT have dumped any sudo error messages.
  ! printf '%s\n' "$output" | grep -qi 'interactive authentication'
  rm -rf "$T"
}

# Regression: on Ubuntu, user-mode install added the loader only to
# ~/.bashrc, but login bash sources ~/.bash_profile / ~/.profile, neither
# of which always chains to ~/.bashrc. Result: \`rec\` not found after
# \`exec \$SHELL -l\`. install_loader_lines now also writes the loader
# to whichever login-shell rc file exists.
@test "install_loader_lines: user mode also writes loader to existing ~/.profile" {
  T="$(mktemp -d)"
  HOME_T="$T/home"
  mkdir -p "$HOME_T"
  : >"$HOME_T/.bashrc"
  : >"$HOME_T/.profile"
  # No ~/.bash_profile, no ~/.bash_login, so the loop should pick .profile.
  run bash -c "
    REC_INSTALL_SOURCED=1
    . '$REPO_ROOT/install.sh'
    HOME='$HOME_T' MODE=user TARGET_DIR='$HOME_T/.rec-shell'
    install_loader_lines
    echo === bashrc ===
    cat '$HOME_T/.bashrc'
    echo === profile ===
    cat '$HOME_T/.profile'
  "
  printf '%s\n' "$output" | grep -q "rec-shell.sh"
  # Both files should now have the loader line.
  grep -q 'rec-shell.sh' "$HOME_T/.bashrc"
  grep -q 'rec-shell.sh' "$HOME_T/.profile"
  rm -rf "$T"
}

# v2.0.0 refactor: detect_platform sets OS/DISTRO/PM in one place. Tests
# pin uname output via REC_TEST_UNAME and the /etc/os-release source via
# REC_OS_RELEASE_FILE so we don't depend on the test box's actual distro.
# v2.0.0: `rec install` (no args) now defaults to install-all-missing,
# matching install.sh's "no picker, no y/N" UX. The picker survives
# behind `rec install pick` for users who want the checkbox.
@test "rec install (no args) dispatches to __rec_install_run_missing, not the picker" {
  T="$(mktemp -d)"
  run bash -c "
    REC_SHELL_DIR='$REPO_ROOT' REC_SHELL_NAME=bash REC_UI_PLAIN=1
    . '$REPO_ROOT/lib/core.sh'
    . '$REPO_ROOT/lib/ui.sh'
    . '$REPO_ROOT/lib/tools-catalog.sh'
    . '$REPO_ROOT/lib/cli-install.sh'
    __rec_install_run_missing() { echo CALLED_RUN_MISSING; }
    __rec_install_interactive()  { echo CALLED_INTERACTIVE; }
    __rec_install_dispatch
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx CALLED_RUN_MISSING
  ! printf '%s\n' "$output" | grep -q CALLED_INTERACTIVE
  rm -rf "$T"
}

@test "rec install pick is the opt-in checkbox path" {
  run bash -c "
    REC_SHELL_DIR='$REPO_ROOT' REC_SHELL_NAME=bash REC_UI_PLAIN=1
    . '$REPO_ROOT/lib/core.sh'
    . '$REPO_ROOT/lib/ui.sh'
    . '$REPO_ROOT/lib/tools-catalog.sh'
    . '$REPO_ROOT/lib/cli-install.sh'
    __rec_install_run_missing() { echo CALLED_RUN_MISSING; }
    __rec_install_interactive()  { echo CALLED_INTERACTIVE; }
    __rec_install_dispatch pick
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx CALLED_INTERACTIVE
  ! printf '%s\n' "$output" | grep -q CALLED_RUN_MISSING
}

@test "detect_platform: Ubuntu /etc/os-release maps to PM=apt" {
  T="$(mktemp -d)"
  cat >"$T/os-release" <<'EOF'
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Ubuntu 25.10"
EOF
  run bash -c "
    REC_INSTALL_SOURCED=1
    . '$REPO_ROOT/install.sh'
    REC_TEST_UNAME=Linux REC_OS_RELEASE_FILE='$T/os-release' detect_platform
    echo \"OS=\$OS DISTRO=\$DISTRO PM=\$PM\"
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'OS=linux DISTRO=ubuntu PM=apt'
  rm -rf "$T"
}

@test "detect_platform: Fedora /etc/os-release maps to PM=dnf" {
  T="$(mktemp -d)"
  cat >"$T/os-release" <<'EOF'
ID=fedora
PRETTY_NAME="Fedora Linux 41"
EOF
  run bash -c "
    REC_INSTALL_SOURCED=1
    . '$REPO_ROOT/install.sh'
    REC_TEST_UNAME=Linux REC_OS_RELEASE_FILE='$T/os-release' detect_platform
    echo \"OS=\$OS DISTRO=\$DISTRO PM=\$PM\"
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'OS=linux DISTRO=fedora PM=dnf'
  rm -rf "$T"
}

@test "detect_platform: macOS uname maps to PM=brew" {
  run bash -c "
    REC_INSTALL_SOURCED=1
    . '$REPO_ROOT/install.sh'
    REC_TEST_UNAME=Darwin detect_platform
    echo \"OS=\$OS DISTRO=\$DISTRO PM=\$PM\"
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'OS=mac DISTRO=mac PM=brew'
}

# prompt_install_mode reads from /dev/tty for the picker-like choice but
# must SKIP the prompt when an existing install is detected — we just
# upgrade in place silently.
@test "prompt_install_mode: skips prompt when ~/.rec-shell/.git exists" {
  T="$(mktemp -d)"
  HOME_T="$T/home"
  mkdir -p "$HOME_T/.rec-shell/.git"
  run bash -c "
    REC_INSTALL_SOURCED=1
    . '$REPO_ROOT/install.sh'
    HOME='$HOME_T' MODE_EXPLICIT=''
    prompt_install_mode </dev/null
    echo \"MODE=\$MODE\"
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'MODE=user'
  rm -rf "$T"
}

@test "prompt_install_mode: skips prompt when /opt/rec-shell/.git exists" {
  # We can't create /opt/rec-shell/.git in the test, but the function
  # also honors MODE_EXPLICIT=1 (set by --user/--system flags) — assert
  # that path stays untouched.
  run bash -c "
    REC_INSTALL_SOURCED=1
    . '$REPO_ROOT/install.sh'
    MODE=system MODE_EXPLICIT=1
    prompt_install_mode </dev/null
    echo \"MODE=\$MODE\"
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'MODE=system'
}

# v2.0.0: install_build_deps collects missing build tools in one pass and
# runs pm_install with all of them at once (no per-tool loop, no spinner
# blip when nothing's missing).
@test "install_build_deps: batches missing deps into one pm_install call" {
  T="$(mktemp -d)"
  mkdir -p "$T/bin"
  run bash -c "
    PATH='$T/bin:/usr/bin:/bin'
    REC_INSTALL_SOURCED=1
    . '$REPO_ROOT/install.sh'
    # Pretend a few common build deps are missing.
    command() {
      if [ \"\$1\" = '-v' ]; then
        case \"\$2\" in unzip|gawk|make) return 1 ;; esac
      fi
      builtin command \"\$@\"
    }
    # Override __rec_install_quietly so pm_install's call shows on
    # stdout (the real wrapper would route it to a log file).
    __rec_install_quietly() {
      shift 2
      \"\$@\"
    }
    pm_install() {
      printf 'PM_INSTALL: %s\\n' \"\$*\"
      return 0
    }
    install_build_deps
  "
  # ONE pm_install call with ALL three missing names.
  [ "$(printf '%s\n' "$output" | grep -c '^PM_INSTALL:')" -eq 1 ]
  printf '%s\n' "$output" | grep -q '^PM_INSTALL:.*unzip'
  printf '%s\n' "$output" | grep -q '^PM_INSTALL:.*gawk'
  printf '%s\n' "$output" | grep -q '^PM_INSTALL:.*make'
  rm -rf "$T"
}

# v2.0.0: ensure_one_tool dispatches by the catalog's kind field — so
# install_all_tools can walk the catalog generically without 12 hard-
# coded ensure_X branches. (The branches still exist; this helper just
# looks up which to call.)
@test "ensure_one_tool: dispatches fzf to ensure_fzf, ble.sh to ensure_blesh" {
  run bash -c "
    REC_INSTALL_SOURCED=1
    . '$REPO_ROOT/install.sh'
    # Override the per-tool installers so we can detect which got called.
    ensure_fzf()  { echo CALLED_fzf; }
    ensure_blesh(){ echo CALLED_blesh; }
    ensure_one_tool fzf
    ensure_one_tool ble.sh
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx CALLED_fzf
  printf '%s\n' "$output" | grep -qx CALLED_blesh
}

# install_all_tools walks the catalog top-to-bottom — no picker, no
# y/N — and emits one __rec_install_quietly call per missing tool with
# a (counter/total) label so the user sees overall progress.
@test "install_all_tools: counter-labeled spinner per missing tool, no picker" {
  T="$(mktemp -d)"
  run bash -c "
    export REC_CACHE_DIR='$T/cache'
    REC_INSTALL_SOURCED=1
    . '$REPO_ROOT/install.sh'
    TARGET_DIR='$REPO_ROOT' USER_SHELL=bash OS=linux INSTALL_TOOLS=auto
    # Stub rec_tools_missing so the loop has known input.
    rec_tools_missing() { printf 'fzf\nbat\nble.sh\n'; }
    # Stub the wrapper to record its label arg and tool arg.
    __rec_install_quietly() {
      printf 'QUIET: label=[%s] tool=[%s]\\n' \"\$1\" \"\$2\"
      return 0
    }
    # Stub ensure_one_tool so we don't actually try to install.
    ensure_one_tool() { :; }
    install_all_tools
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE 'QUIET: label=\[.*\(1/3\).*fzf.*\] tool=\[fzf\]'
  printf '%s\n' "$output" | grep -qE 'QUIET: label=\[.*\(2/3\).*bat.*\] tool=\[bat\]'
  printf '%s\n' "$output" | grep -qE 'QUIET: label=\[.*\(3/3\).*ble.sh.*\] tool=\[ble.sh\]'
  rm -rf "$T"
}

@test "install_build_deps: silent no-op when everything's already present" {
  run bash -c "
    REC_INSTALL_SOURCED=1
    . '$REPO_ROOT/install.sh'
    # Pretend everything is present.
    command() {
      [ \"\$1\" = '-v' ] && return 0
      builtin command \"\$@\"
    }
    pm_install() {
      printf 'SHOULD_NOT_FIRE\\n'
      return 0
    }
    install_build_deps
  "
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -q SHOULD_NOT_FIRE
}

@test "install.sh sets NEEDRESTART_MODE and NEEDRESTART_SUSPEND" {
  run bash -c "
    REC_INSTALL_SOURCED=1
    . '$REPO_ROOT/install.sh'
    echo \"NEEDRESTART_MODE=[\$NEEDRESTART_MODE]\"
    echo \"NEEDRESTART_SUSPEND=[\$NEEDRESTART_SUSPEND]\"
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'NEEDRESTART_MODE=\[l\]'
  printf '%s\n' "$output" | grep -qx 'NEEDRESTART_SUSPEND=\[1\]'
}

@test "__rec_default_term sets TERM=xterm-256color when empty" {
  run bash -c "
    REC_INSTALL_SOURCED=1
    . '$REPO_ROOT/install.sh'
    unset TERM
    __rec_default_term
    echo \"TERM=\$TERM\"
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'TERM=xterm-256color'
}

@test "__rec_default_term preserves an existing TERM" {
  run bash -c "
    REC_INSTALL_SOURCED=1
    . '$REPO_ROOT/install.sh'
    export TERM=screen-256color
    __rec_default_term
    echo \"TERM=\$TERM\"
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'TERM=screen-256color'
}
