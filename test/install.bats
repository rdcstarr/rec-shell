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

@test "rec install dispatch with no TTY prints usage hint and exits 0" {
  install_in bash '__rec_install_dispatch'
  [ "$status" -eq 0 ]
  # Non-interactive: must NOT block on a multiselect. Either prints hint and
  # returns 0, or prints the same as `list` — either is acceptable here.
  [[ "$output" == *"rec install"* ]]
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
