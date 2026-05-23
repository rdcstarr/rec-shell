# shellcheck shell=sh
# shellcheck disable=SC1090,SC1091 # we source the config and the loader by path
#
# lib/cli.sh — the body of the `rec-shell` command. Sourced lazily on first use
# (see rec-shell.sh) so it costs nothing at shell startup.

__rec_dispatch() {
  _rc_cmd="${1:-help}"
  [ $# -gt 0 ] && shift
  case "$_rc_cmd" in
    update) __rec_cmd_update "$@" ;;
    check) __rec_cmd_check "$@" ;;
    version | --version | -v) __rec_cmd_version "$@" ;;
    reload) __rec_cmd_reload "$@" ;;
    doctor) __rec_cmd_doctor "$@" ;;
    enable) __rec_cmd_toggle enable "$@" ;;
    disable) __rec_cmd_toggle disable "$@" ;;
    git) __rec_cmd_git "$@" ;;
    uninstall) __rec_cmd_uninstall "$@" ;;
    help | --help | -h) __rec_cmd_help ;;
    *)
      printf 'rec-shell: unknown command "%s"\n\n' "$_rc_cmd" >&2
      __rec_cmd_help >&2
      return 2
      ;;
  esac
}

__rec_cmd_version() {
  _rcv_ver="$(rec_installed_version 2>/dev/null || echo '?')"
  _rcv_sha=""
  if [ -d "$REC_SHELL_DIR/.git" ] && rec_have git; then
    _rcv_sha="$(git -C "$REC_SHELL_DIR" rev-parse --short HEAD 2>/dev/null)"
  fi
  if [ -n "$_rcv_sha" ]; then
    printf 'rec-shell %s (%s) — %s on %s\n' "$_rcv_ver" "$_rcv_sha" "$REC_SHELL_NAME" "$REC_OS"
  else
    printf 'rec-shell %s — %s on %s\n' "$_rcv_ver" "$REC_SHELL_NAME" "$REC_OS"
  fi
}

__rec_cmd_check() {
  rec_have curl || {
    printf 'rec-shell: curl is required for update checks\n' >&2
    return 1
  }
  _rcc_installed="$(rec_installed_version 2>/dev/null || echo '?')"
  _rcc_latest="$(rec_update_fetch_latest)" || _rcc_latest=""
  if [ -z "$_rcc_latest" ]; then
    printf 'rec-shell: could not reach the update server.\n' >&2
    return 1
  fi
  command mkdir -p "$REC_CACHE_DIR" 2>/dev/null \
    && printf '%s\n%s\n' "$(date +%s)" "$_rcc_latest" >"$REC_CACHE_FILE" 2>/dev/null
  if rec_semver_gt "$_rcc_latest" "$_rcc_installed"; then
    printf 'rec-shell %s is available (you have %s).\nRun: rec update\n' "$_rcc_latest" "$_rcc_installed"
  else
    printf 'rec-shell is up to date (%s).\n' "$_rcc_installed"
  fi
}

__rec_cmd_update() {
  rec_have git || {
    printf 'rec-shell: git is required to update\n' >&2
    return 1
  }
  [ -d "$REC_SHELL_DIR/.git" ] || {
    printf 'rec-shell: %s is not a git checkout; reinstall with the installer.\n' "$REC_SHELL_DIR" >&2
    return 1
  }

  _rcu_sudo=no
  if [ ! -w "$REC_SHELL_DIR/.git" ]; then
    if rec_have sudo; then
      _rcu_sudo=yes
      printf 'rec-shell: system install detected; using sudo...\n'
    else
      printf 'rec-shell: need write access to %s (run as root)\n' "$REC_SHELL_DIR" >&2
      return 1
    fi
  fi

  __rec_git() {
    if [ "$_rcu_sudo" = yes ]; then
      sudo git -C "$REC_SHELL_DIR" "$@"
    else
      git -C "$REC_SHELL_DIR" "$@"
    fi
  }

  __rec_git fetch --tags --prune origin || {
    printf 'rec-shell: fetch failed (offline?)\n' >&2
    return 1
  }

  _rcu_tag="$(__rec_git rev-list --tags --max-count=1 2>/dev/null)"
  [ -n "$_rcu_tag" ] && _rcu_tag="$(__rec_git describe --tags "$_rcu_tag" 2>/dev/null)"
  if [ -n "$_rcu_tag" ]; then
    __rec_git checkout -q "$_rcu_tag" 2>/dev/null || __rec_git pull --ff-only || {
      printf 'rec-shell: update failed\n' >&2
      return 1
    }
  else
    __rec_git pull --ff-only || {
      printf 'rec-shell: update failed\n' >&2
      return 1
    }
  fi

  _rcu_new="$(rec_installed_version 2>/dev/null || echo '?')"
  command mkdir -p "$REC_CACHE_DIR" 2>/dev/null \
    && printf '%s\n%s\n' "$(date +%s)" "$_rcu_new" >"$REC_CACHE_FILE" 2>/dev/null
  printf 'rec-shell updated to %s.\n' "$_rcu_new"
  # `rec` is a function in the live shell, so apply the update immediately.
  __rec_cmd_reload
}

__rec_cmd_reload() {
  unset REC_SHELL_LOADED
  . "$REC_SHELL_DIR/rec-shell.sh"
  printf 'rec-shell reloaded (%s).\n' "$(rec_installed_version 2>/dev/null || echo '?')"
}

__rec_cmd_doctor() {
  printf 'rec-shell doctor\n'
  printf '  version:  %s\n' "$(rec_installed_version 2>/dev/null || echo '?')"
  printf '  shell:    %s\n' "$REC_SHELL_NAME"
  printf '  os:       %s\n' "$REC_OS"
  printf '  dir:      %s\n' "$REC_SHELL_DIR"
  printf '  config:   %s\n' "$REC_CONFIG_FILE"
  [ -n "${REC_DISABLED_MODULES:-}" ] && printf '  disabled: %s\n' "$REC_DISABLED_MODULES"

  if rec_have git; then __rec_ok "git present"; else __rec_no "git missing (needed for updates)"; fi
  if rec_have curl; then __rec_ok "curl present"; else __rec_no "curl missing (needed for update checks)"; fi
  if rec_have "${REC_OMP_BIN:-oh-my-posh}"; then
    __rec_ok "oh-my-posh present"
  else
    __rec_no "oh-my-posh missing (prompt disabled)"
  fi
  if [ -r "${REC_THEME:-$REC_SHELL_DIR/themes/recweb.omp.json}" ]; then
    __rec_ok "theme readable"
  else
    __rec_no "theme not found"
  fi
  if [ -d "$REC_SHELL_DIR/.git" ]; then
    __rec_ok "git checkout (updatable)"
  else
    __rec_no "not a git checkout (reinstall to enable updates)"
  fi
  __rec_doctor_rc
}

__rec_ok() { printf '  [ok]   %s\n' "$1"; }
__rec_no() { printf '  [warn] %s\n' "$1"; }

__rec_doctor_rc() {
  for _rcd_rc in "$HOME/.zshrc" "$HOME/.bashrc" /etc/zshrc /etc/zsh/zshrc /etc/bash.bashrc /etc/bashrc; do
    [ -r "$_rcd_rc" ] || continue
    if command grep -q '# rec-shell' "$_rcd_rc" 2>/dev/null; then
      __rec_ok "loader line present in $_rcd_rc"
      return 0
    fi
  done
  __rec_no "loader line not found in any rc (run the installer)"
}

# enable/disable a module by editing REC_DISABLED_MODULES in the user config.
__rec_cmd_toggle() {
  _rct_action="$1"
  _rct_mod="${2:-}"
  if [ -z "$_rct_mod" ]; then
    printf 'usage: rec-shell %s <module>\n' "$_rct_action" >&2
    return 2
  fi

  command mkdir -p "$REC_CONFIG_DIR" 2>/dev/null
  _rct_cur="$(
    [ -r "$REC_CONFIG_FILE" ] && . "$REC_CONFIG_FILE" 2>/dev/null
    printf '%s' "${REC_DISABLED_MODULES:-}"
  )"

  # zsh does not word-split unquoted variables by default; enable it locally so
  # the loop iterates each module (reverts automatically on function return).
  if [ -n "${ZSH_VERSION:-}" ]; then
    setopt local_options sh_word_split 2>/dev/null
  fi
  _rct_new=""
  # shellcheck disable=SC2086 # intentional word-split of the space-separated list
  for _rct_x in $_rct_cur; do
    [ "$_rct_x" = "$_rct_mod" ] && continue
    _rct_new="$_rct_new $_rct_x"
  done
  [ "$_rct_action" = disable ] && _rct_new="$_rct_new $_rct_mod"
  _rct_new="$(printf '%s' "$_rct_new" | sed 's/^ *//; s/  */ /g; s/ *$//')"

  __rec_config_set REC_DISABLED_MODULES "$_rct_new"
  printf 'rec-shell: %sd "%s". Run: rec reload\n' "$_rct_action" "$_rct_mod"
}

# __rec_config_set KEY VALUE -> replace (or add) KEY="VALUE" in the config file.
__rec_config_set() {
  _rcs_key="$1"
  _rcs_val="$2"
  _rcs_tmp="$REC_CONFIG_FILE.tmp.$$"
  if [ -f "$REC_CONFIG_FILE" ]; then
    command grep -v "^${_rcs_key}=" "$REC_CONFIG_FILE" >"$_rcs_tmp" 2>/dev/null || : >"$_rcs_tmp"
  else
    : >"$_rcs_tmp"
  fi
  printf '%s="%s"\n' "$_rcs_key" "$_rcs_val" >>"$_rcs_tmp"
  mv -f "$_rcs_tmp" "$REC_CONFIG_FILE"
}

# git command group, lazy-loaded from lib/cli-git.sh on first use.
__rec_cmd_git() {
  if ! command -v __rec_git_dispatch >/dev/null 2>&1; then
    if [ -r "$REC_SHELL_DIR/lib/cli-git.sh" ]; then
      . "$REC_SHELL_DIR/lib/cli-git.sh"
    else
      printf 'rec: git commands unavailable (missing lib/cli-git.sh)\n' >&2
      return 1
    fi
  fi
  __rec_git_dispatch "$@"
}

__rec_cmd_uninstall() {
  if [ -r "$REC_SHELL_DIR/uninstall.sh" ]; then
    sh "$REC_SHELL_DIR/uninstall.sh" "$@"
  else
    printf 'rec-shell: uninstaller not found at %s\n' "$REC_SHELL_DIR/uninstall.sh" >&2
    return 1
  fi
}

__rec_cmd_help() {
  cat <<'EOF'
rec-shell — modern bash & zsh configuration

Usage: rec <command>     (rec-shell also works)

Commands:
  update            Update to the latest released version (git pull to newest tag)
  check             Check now whether a newer version is available
  version           Show installed version, commit and shell/OS
  reload            Re-source rec-shell in the current shell
  doctor            Diagnose the installation
  git <command>     Git helpers: sync, push, release, init (see: rec git help)
  enable <module>   Re-enable a module (e.g. ssh, prompt, integrations)
  disable <module>  Disable a module
  uninstall         Remove rec-shell (keeps your config; pass --purge to remove it)
  help              Show this help
EOF
}
