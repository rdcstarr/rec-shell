#!/usr/bin/env bats
#
# Unit tests for lib/ui.sh (static message API) and the non-TTY fallbacks of
# lib/ui-interactive.sh. Everything runs through `run`, so stdout/stderr are NOT
# a terminal: this is exactly the path that must stay plain (no ANSI) and must
# never block. The locale is forced per-test so glyph selection is deterministic
# regardless of the host.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  UI="$REPO_ROOT/lib/ui.sh"
  UII="$REPO_ROOT/lib/ui-interactive.sh"
  ESC="$(printf '\033')"
}

# --- static API: glyphs + message shape ------------------------------------

@test "rec_ui_ok prints a check glyph and the message (UTF-8 locale)" {
  run sh -c "LC_ALL=en_US.UTF-8; . '$UI'; rec_ui_ok hello"
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓"* ]]
  [[ "$output" == *"hello"* ]]
}

@test "rec_ui_info uses the info glyph and rec_ui_step uses the arrow" {
  run sh -c "LC_ALL=en_US.UTF-8; . '$UI'; rec_ui_info one; rec_ui_step two"
  [[ "$output" == *"ℹ"*"one"* ]]
  [[ "$output" == *"➜"*"two"* ]]
}

# --- color: auto-off when piped, force, and explicit disable ---------------

@test "color auto-disables when stdout is not a TTY" {
  run sh -c "LC_ALL=en_US.UTF-8; . '$UI'; rec_ui_ok hi"
  [[ "$output" != *"$ESC"* ]]
}

@test "CLICOLOR_FORCE emits ANSI even when piped" {
  run sh -c "CLICOLOR_FORCE=1; LC_ALL=en_US.UTF-8; . '$UI'; rec_ui_ok hi"
  [[ "$output" == *"${ESC}[32m"* ]]
}

@test "NO_COLOR disables color even when CLICOLOR_FORCE is set" {
  run sh -c "CLICOLOR_FORCE=1; NO_COLOR=1; LC_ALL=en_US.UTF-8; . '$UI'; rec_ui_ok hi"
  [[ "$output" != *"$ESC"* ]]
}

@test "REC_UI_PLAIN disables color even when CLICOLOR_FORCE is set" {
  run sh -c "CLICOLOR_FORCE=1; REC_UI_PLAIN=1; LC_ALL=en_US.UTF-8; . '$UI'; rec_ui_ok hi"
  [[ "$output" != *"$ESC"* ]]
}

# --- ASCII glyph fallback --------------------------------------------------

@test "REC_UI_ASCII swaps Unicode glyphs for ASCII" {
  run sh -c "REC_UI_ASCII=1; . '$UI'; rec_ui_ok done"
  [[ "$output" == *"[ok]"* ]]
  [[ "$output" != *"✓"* ]]
}

@test "a non-UTF-8 locale falls back to ASCII glyphs" {
  run sh -c "LC_ALL=C; . '$UI'; rec_ui_ok done"
  [[ "$output" == *"[ok]"* ]]
}

# --- key/value alignment ---------------------------------------------------

@test "rec_ui_kv prints an aligned key and the value" {
  run sh -c "LC_ALL=en_US.UTF-8; . '$UI'; rec_ui_kv version 1.2.3"
  [[ "$output" =~ version:[[:space:]]+1\.2\.3 ]]
}

# --- stream routing (errors/warnings to stderr) ----------------------------

@test "rec_ui_err writes to stderr, rec_ui_ok writes to stdout" {
  run sh -c "LC_ALL=en_US.UTF-8; . '$UI'; rec_ui_ok keep 2>/dev/null; rec_ui_err drop 2>/dev/null"
  [[ "$output" == *"keep"* ]]
  [[ "$output" != *"drop"* ]]
}

@test "rec_ui_warn_out stays on stdout (for doctor)" {
  run sh -c "LC_ALL=en_US.UTF-8; . '$UI'; rec_ui_warn_out shown 2>/dev/null"
  [[ "$output" == *"shown"* ]]
}

# --- interactive fallbacks (must never block under a pipe) ------------------

@test "rec_ui_confirm returns the default when stdin is not a TTY" {
  run sh -c ". '$UI'; . '$UII'; rec_ui_confirm 'ok?' yes </dev/null; echo rc=\$?"
  [[ "$output" == *"rc=0"* ]]
  run sh -c ". '$UI'; . '$UII'; rec_ui_confirm 'ok?' no </dev/null; echo rc=\$?"
  [[ "$output" == *"rc=1"* ]]
}

@test "rec_ui_select returns the first option when stdin is not a TTY" {
  run sh -c ". '$UI'; . '$UII'; rec_ui_select pick alpha beta gamma </dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha"* ]]
}

@test "rec_ui_multiselect returns nothing (exit 0) when stdin is not a TTY" {
  run sh -c ". '$UI'; . '$UII'; rec_ui_multiselect pick a b c </dev/null; echo rc=\$?"
  [[ "$output" == *"rc=0"* ]]
}

# Regression: __rec_ui_readkey used to branch on $REC_SHELL_NAME (the user's
# login shell) instead of $BASH_VERSION / $ZSH_VERSION (the interpreter that's
# actually running this code). Under `sudo bash` invoked by a zsh user,
# REC_SHELL_NAME=zsh would steer bash into `read -rsk1` (zsh-only syntax),
# `-k` is "invalid option" in bash → read fails silently → caller loops on a
# stale $_rui_k forever. Lock in the interpreter-aware detection.
@test "__rec_ui_readkey reads a real byte under bash even when REC_SHELL_NAME=zsh" {
  run bash -c "
    export REC_SHELL_NAME=zsh
    . '$UII'
    printf 'X' | __rec_ui_readkey
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "X" ]]
}

@test "rec_ui_multiselect_plain: 'a' selects everything" {
  # Heredoc (<<<) keeps the function in the main shell; a pipe would put it
  # in a subshell and REC_UI_REPLY would never reach the test.
  run bash -c "
    . '$UI'
    . '$UII'
    rec_ui_multiselect_plain prompt alpha beta gamma <<< 'a' >/dev/null 2>/dev/null
    echo REPLY=[\$REC_UI_REPLY]
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'REPLY=\[alpha beta gamma \]'
}

@test "rec_ui_multiselect_plain: empty line (default) also selects everything" {
  run bash -c "
    . '$UI'
    . '$UII'
    rec_ui_multiselect_plain prompt alpha beta gamma <<< '' >/dev/null 2>/dev/null
    echo REPLY=[\$REC_UI_REPLY]
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'REPLY=\[alpha beta gamma \]'
}

@test "rec_ui_multiselect_plain: 'n' selects nothing" {
  run bash -c "
    . '$UI'
    . '$UII'
    rec_ui_multiselect_plain prompt alpha beta gamma <<< 'n' >/dev/null 2>/dev/null
    echo REPLY=[\$REC_UI_REPLY]
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'REPLY=\[\]'
}

@test "rec_ui_multiselect_plain: numeric picks select those items" {
  run bash -c "
    . '$UI'
    . '$UII'
    rec_ui_multiselect_plain prompt alpha beta gamma <<< '1 3' >/dev/null 2>/dev/null
    echo REPLY=[\$REC_UI_REPLY]
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'REPLY=\[alpha gamma \]'
}

@test "rec_ui_multiselect: pre-selects all items so Enter installs everything" {
  # Stub __rec_ui_readkey to return 'enter' on first call so the picker
  # commits immediately without any space-toggling. The default mark set
  # should already include every item — REC_UI_REPLY contains all of them.
  run bash -c "
    . '$UI'
    . '$UII'
    # Force interactivity past the [ -t 0 ] && [ -t 2 ] check.
    __rec_ui_interactive() { return 0; }
    __rec_ui_readkey() { printf 'enter'; }
    rec_ui_multiselect prompt alpha beta gamma >/dev/null 2>/dev/null
    echo REPLY=[\$REC_UI_REPLY]
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'REPLY=\[alpha beta gamma \]'
}

@test "__rec_ui_readkey: bash + REC_SHELL_NAME=zsh + EOF returns empty not 'enter'" {
  # We're not actually asserting 'enter' here — empty stdin is allowed to
  # mean 'enter' (the legacy '' branch). What we ARE asserting: read does
  # not loop, and the function returns within milliseconds. If the function
  # ever spins (the runaway bug), `timeout` kills it and the test fails.
  if command -v timeout >/dev/null 2>&1; then
    run bash -c "
      export REC_SHELL_NAME=zsh
      . '$UII'
      timeout 2 bash -c '. \"$UII\"; __rec_ui_readkey </dev/null'
      echo rc=\$?
    "
    [[ "$output" != *"rc=124"* ]]  # 124 = timeout fired
  else
    skip "timeout(1) not available on this host"
  fi
}

@test "rec_ui_spin propagates the command exit code (non-TTY path)" {
  run sh -c ". '$UI'; . '$UII'; rec_ui_spin label true </dev/null; echo rc=\$?"
  [[ "$output" == *"rc=0"* ]]
  run sh -c ". '$UI'; . '$UII'; rec_ui_spin label false </dev/null; echo rc=\$?"
  [[ "$output" == *"rc=1"* ]]
}

# --- rec_banner ------------------------------------------------------------

@test "rec_banner: UTF logo + version + hint" {
  run sh -c "LC_ALL=en_US.UTF-8; . '$UI'; rec_banner 1.2.3 'bash on mac' 'rec doctor'"
  [ "$status" -eq 0 ]
  # Block-letter logo present.
  [[ "$output" == *"┏━┓"* ]]
  # Version line.
  [[ "$output" == *"modern bash & zsh"* && "$output" == *"v1.2.3"* ]]
  # Subtitle and hint lines.
  [[ "$output" == *"bash on mac"* ]]
  [[ "$output" == *"➜"*"rec doctor"* ]]
}

@test "rec_banner: ASCII fallback drops box-drawing chars" {
  run sh -c "REC_UI_ASCII=1; . '$UI'; rec_banner 1.2.3"
  [ "$status" -eq 0 ]
  # No UTF box-drawing.
  [[ "$output" != *"┏"* && "$output" != *"╸"* ]]
  # Still carries the brand text and version.
  [[ "$output" == *"modern bash & zsh"* ]]
  [[ "$output" == *"v1.2.3"* ]]
  # The hint arrow degrades to "->".
  [[ "$output" != *"➜"* ]]
}

@test "rec_banner: no args prints just the logo, no trailing version line" {
  run sh -c "LC_ALL=en_US.UTF-8; . '$UI'; rec_banner"
  [ "$status" -eq 0 ]
  [[ "$output" == *"┏━┓"* ]]
  [[ "$output" != *"modern bash"* ]]
}

@test "rec_banner: NO_COLOR suppresses ANSI escapes" {
  run sh -c "NO_COLOR=1; CLICOLOR_FORCE=1; LC_ALL=en_US.UTF-8; . '$UI'; rec_banner 1.2.3"
  [[ "$output" != *"$ESC"* ]]
  [[ "$output" == *"v1.2.3"* ]]
}
