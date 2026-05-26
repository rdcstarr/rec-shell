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
  # Build space-separated args for rec_ui_multiselect.
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

# Common exec path: invoke install.sh --tools-only with the given CSV list.
__rec_install_exec() {
  _rin_csv="$1"
  if [ ! -r "$REC_SHELL_DIR/install.sh" ]; then
    rec_ui_err "install.sh not found at $REC_SHELL_DIR/install.sh"
    unset _rin_csv
    return 1
  fi
  sh "$REC_SHELL_DIR/install.sh" --tools-only --unattended --tools="$_rin_csv"
  unset _rin_csv
}
