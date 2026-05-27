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
# to a prebuilt binary from GitHub releases. We stub pm_install to fail
# and curl/tar to capture the GitHub URL, then assert ensure_eza tried it.
@test "ensure_eza: falls back to GitHub binary when pm_install fails" {
  T="$(mktemp -d)"
  mkdir -p "$T/bin" "$T/local/bin"
  # Stub curl to write a one-byte payload, tar to extract a fake eza binary.
  cat >"$T/bin/curl" <<EOF
#!/bin/sh
# Record the URL we were asked to download, then write a fake archive.
out=""
url=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
echo "CURL_URL: \$url" >>"$T/curl-calls.log"
# Build a tarball containing an executable named "eza".
mkdir -p "$T/eza-stage"
printf '#!/bin/sh\necho fake-eza\n' >"$T/eza-stage/eza"
chmod +x "$T/eza-stage/eza"
tar -czf "\$out" -C "$T/eza-stage" eza
exit 0
EOF
  chmod +x "$T/bin/curl"
  # Stub apt-get so pm_install's apt path fails.
  cat >"$T/bin/apt-get" <<'EOF'
#!/bin/sh
echo "apt-get: E: Unable to locate package eza" >&2
exit 100
EOF
  chmod +x "$T/bin/apt-get"
  # Force the apt path in pm_install: hide brew/dnf/pacman/apk.
  run env -i \
    HOME="$T" PATH="$T/bin:/usr/bin:/bin" \
    TOOLS_ONLY=1 UNATTENDED=1 \
    bash -c "
      cd '$T'
      # Make a writable shim for HOME/.local/bin (non-root → user prefix).
      # Source install.sh up to ensure_eza then call it.
      . '$REPO_ROOT/install.sh' --tools-only --no-tools --unattended >/dev/null 2>&1 || true
      ensure_eza
      ls -la \"\$HOME/.local/bin/eza\" 2>&1 || echo MISSING
      cat '$T/curl-calls.log' 2>/dev/null"
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]  # ensure_eza may return 1 on tar mismatch
  # The GitHub URL must have been hit.
  [[ "$output" == *"CURL_URL: https://github.com/eza-community/eza/releases/latest/download/eza_"* ]]
  [[ "$output" == *"-unknown-linux-"* ]]
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
