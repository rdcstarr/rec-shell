# shellcheck shell=sh
#
# lib/cli-install.sh — the `rec install` command. Lazy-loaded by lib/cli.sh.
# Drives an interactive multiselect over rec_tools_catalog and shells out
# to install.sh --tools-only to do the actual installation.

__rec_install_dispatch() {
  _rin_cmd="${1:-}"
  case "$_rin_cmd" in
    help | --help | -h)
      __rec_install_help
      return 0
      ;;
    list | ls)
      __rec_install_list
      return $?
      ;;
    all)
      __rec_install_run_missing
      return $?
      ;;
    '')
      __rec_install_interactive
      return $?
      ;;
    *)
      # Treat positional args as a list of tool names.
      __rec_install_run "$@"
      return $?
      ;;
  esac
}

__rec_install_help() {
  cat <<'EOF'
rec install — install modern CLI tools from the rec-shell catalog

Usage:
  rec install              Interactive multiselect of MISSING tools.
  rec install list         Show every catalog tool with [✓]/[✗] status.
  rec install all          Install every tool that is currently missing.
  rec install <tool>...    Install the named tools (skip prompts).
  rec install help         Show this help.

Tools are installed via install.sh --tools-only, so this never touches your
shell rc files or re-clones the repo.
EOF
}

# `rec install list` -> show every catalog tool with a status marker.
__rec_install_list() {
  rec_ui_heading "rec-shell tools"
  rec_tools_catalog | while IFS='|' read -r _ril_name _ril_bin _ril_kind _ril_pkgs _ril_desc; do
    [ -z "$_ril_name" ] && continue
    if rec_tools_present "$_ril_name"; then
      __rec_ui_emit 1 "$REC_UI_S_GREEN" "$REC_UI_G_OK"
      printf ' '
    else
      __rec_ui_emit 1 "$REC_UI_S_YELLOW" "$REC_UI_G_WARN"
      printf ' '
    fi
    __rec_ui_emit 1 "$REC_UI_S_CYAN" "$(printf '%-24s' "$_ril_name")"
    __rec_ui_emit 1 "$REC_UI_S_DIM" " $_ril_desc"
    printf '\n'
  done
  unset _ril_name _ril_bin _ril_kind _ril_pkgs _ril_desc
}

# `rec install <name>...` -> validate names against the catalog, then install.
__rec_install_run() {
  if [ $# -eq 0 ]; then
    rec_ui_err "rec install: at least one tool name is required"
    return 2
  fi
  _rin_valid=""
  for _rin_n in "$@"; do
    if [ -z "$(rec_tools_field "$_rin_n" 1)" ]; then
      rec_ui_err "rec install: unknown tool '$_rin_n'"
      unset _rin_n _rin_valid
      return 2
    fi
    _rin_valid="$_rin_valid,$_rin_n"
  done
  _rin_valid="${_rin_valid#,}"
  __rec_install_exec "$_rin_valid"
  unset _rin_n _rin_valid
}

# `rec install all` -> compute the missing set, install everything in one go.
__rec_install_run_missing() {
  _rin_miss="$(rec_tools_missing | awk 'NF' | paste -sd, -)"
  if [ -z "$_rin_miss" ]; then
    rec_ui_ok "All tools already installed."
    unset _rin_miss
    return 0
  fi
  rec_ui_info "Installing: $_rin_miss"
  __rec_install_exec "$_rin_miss"
  unset _rin_miss
}

# Interactive multi-select over the MISSING tools.
__rec_install_interactive() {
  _rin_miss="$(rec_tools_missing | awk 'NF')"
  if [ -z "$_rin_miss" ]; then
    rec_ui_ok "All tools already installed."
    unset _rin_miss
    return 0
  fi
  if ! rec_ui_interactive_load || ! __rec_ui_interactive; then
    rec_ui_info 'Non-interactive shell; printing the list instead.'
    __rec_install_list
    rec_ui_note 'Pick by name: rec install <tool> ... (or: rec install all)'
    unset _rin_miss
    return 0
  fi
  # Split the newline list into positional args for rec_ui_multiselect.
  # zsh does NOT word-split unquoted variable expansion by default, so the
  # whole multi-line string would land as a single positional and break the
  # multiselect's cursor math. Toggle sh_word_split locally on zsh (mirrors
  # the pattern in __rec_toggle_interactive in lib/cli.sh).
  if [ -n "${ZSH_VERSION:-}" ]; then
    setopt local_options sh_word_split 2>/dev/null
  fi
  set --
  _rin_OLDIFS="$IFS"
  IFS='
'
  # shellcheck disable=SC2086  # intentional word split on newline
  set -- $_rin_miss
  IFS="$_rin_OLDIFS"
  rec_ui_multiselect "Tools to install (space to toggle, a = all, enter = confirm)" "$@" >/dev/null
  if [ -z "${REC_UI_REPLY:-}" ]; then
    rec_ui_info 'Nothing selected.'
    unset _rin_miss _rin_OLDIFS
    return 0
  fi
  _rin_csv="$(printf '%s' "$REC_UI_REPLY" | tr ' ' ',')"
  __rec_install_exec "$_rin_csv"
  unset _rin_miss _rin_OLDIFS _rin_csv
}

# Common exec path: split the CSV tool list and install each tool individually
# under a spinner, redirecting the (typically verbose) apt/curl output to a
# per-tool log file at $REC_CACHE_DIR/install-logs/<tool>.log. atuin is the
# one exception — its upstream installer asks the user a few questions, so
# we let its output through directly. install.sh itself REQUIRES bash (it
# uses `set -o pipefail`, `local`, `[[ ]]`), so we never call it via `sh` —
# on Debian-family systems /bin/sh is dash and would refuse `pipefail`.
__rec_install_exec() {
  _rin_csv="$1"
  if [ ! -r "$REC_SHELL_DIR/install.sh" ]; then
    rec_ui_err "install.sh not found at $REC_SHELL_DIR/install.sh"
    unset _rin_csv
    return 1
  fi
  if ! rec_have bash; then
    rec_ui_err "bash is required to run install.sh (and rec-shell itself)"
    unset _rin_csv
    return 1
  fi
  # rec_ui_spin lives in lib/ui-interactive.sh — make sure it's loaded.
  rec_ui_interactive_load 2>/dev/null
  _rin_logdir="${REC_CACHE_DIR:-$HOME/.cache/rec-shell}/install-logs"
  # `command mkdir` skips the user's `mkdir='mkdir -pv'` alias from
  # modules/aliases.sh — otherwise the create message leaks to the terminal
  # and breaks the clean spinner layout we want.
  command mkdir -p "$_rin_logdir" 2>/dev/null
  _rin_ok=0
  _rin_fail=0
  _rin_failed=""
  _rin_OLDIFS="$IFS"
  IFS=','
  # shellcheck disable=SC2086 # intentional word-split on comma
  for _rin_tool in $_rin_csv; do
    [ -z "$_rin_tool" ] && continue
    _rin_kind="$(rec_tools_field "$_rin_tool" 3)"
    _rin_log="$_rin_logdir/$_rin_tool.log"
    case "$_rin_kind" in
      special-atuin)
        # atuin's upstream installer has interactive prompts (sync sign-up,
        # AI opt-in, daemon opt-in). Let output through so the user sees and
        # answers them; tee a copy into the log for post-mortem.
        rec_ui_info "Installing $_rin_tool — interactive, may ask a few questions..."
        if bash "$REC_SHELL_DIR/install.sh" --tools-only --unattended \
          --tools="$_rin_tool" 2>&1 | tee "$_rin_log"; then
          _rin_ok=$((_rin_ok + 1))
        else
          _rin_fail=$((_rin_fail + 1))
          _rin_failed="$_rin_failed $_rin_tool"
        fi
        ;;
      *)
        # Everything else: spinner + log when available, otherwise a
        # one-line step + log. rec_ui_spin already reports ✓/✗; the
        # fallback path emits its own ok/err.
        if command -v rec_ui_spin >/dev/null 2>&1; then
          if rec_ui_spin "installing $_rin_tool" \
            sh -c "bash '$REC_SHELL_DIR/install.sh' --tools-only --unattended --tools='$_rin_tool' >'$_rin_log' 2>&1"; then
            _rin_ok=$((_rin_ok + 1))
          else
            rec_ui_note "log: $_rin_log"
            _rin_fail=$((_rin_fail + 1))
            _rin_failed="$_rin_failed $_rin_tool"
          fi
        else
          rec_ui_step "installing $_rin_tool"
          if bash "$REC_SHELL_DIR/install.sh" --tools-only --unattended \
            --tools="$_rin_tool" >"$_rin_log" 2>&1; then
            rec_ui_ok "$_rin_tool installed"
            _rin_ok=$((_rin_ok + 1))
          else
            rec_ui_err "$_rin_tool failed"
            rec_ui_note "log: $_rin_log"
            _rin_fail=$((_rin_fail + 1))
            _rin_failed="$_rin_failed $_rin_tool"
          fi
        fi
        ;;
    esac
  done
  IFS="$_rin_OLDIFS"
  # Bring freshly-installed binaries into the live shell's PATH so the next
  # `rec doctor` / `rec install list` immediately reflects them. atuin's
  # upstream installer drops binaries in ~/.atuin/bin and fzf's user-mode
  # clone install drops them in ~/.fzf/bin — neither is on PATH by default.
  for _rin_extra in "$HOME/.atuin/bin" "$HOME/.fzf/bin"; do
    [ -d "$_rin_extra" ] || continue
    case ":$PATH:" in
      *":$_rin_extra:"*) continue ;;
    esac
    PATH="$_rin_extra:$PATH"
  done
  export PATH
  printf '\n'
  if [ "$_rin_fail" -eq 0 ]; then
    rec_ui_ok "All $_rin_ok tool(s) installed."
  else
    rec_ui_warn "Installed $_rin_ok, failed $_rin_fail —$_rin_failed"
    rec_ui_note "Failure logs in $_rin_logdir/"
  fi
  unset _rin_csv _rin_logdir _rin_ok _rin_fail _rin_failed _rin_OLDIFS \
    _rin_tool _rin_kind _rin_log _rin_extra
}
