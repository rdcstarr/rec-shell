# shellcheck shell=sh
# shellcheck disable=SC1090,SC1091 # we source the config and the loader by path
#
# lib/cli.sh — the body of the `rec-shell` command. Sourced lazily on first use
# (see rec-shell.sh) so it costs nothing at shell startup.

__rec_dispatch() {
  # Bare `rec` on a terminal opens the interactive command picker.
  if [ $# -eq 0 ]; then
    __rec_cmd_menu
    return $?
  fi
  _rc_cmd="$1"
  shift
  case "$_rc_cmd" in
    update) __rec_cmd_update "$@" ;;
    check) __rec_cmd_check "$@" ;;
    version | --version | -v) __rec_cmd_version "$@" ;;
    reload) __rec_cmd_reload "$@" ;;
    doctor) __rec_cmd_doctor "$@" ;;
    enable) __rec_cmd_toggle enable "$@" ;;
    disable) __rec_cmd_toggle disable "$@" ;;
    git) __rec_cmd_git "$@" ;;
    ssh) __rec_cmd_ssh "$@" ;;
    port) __rec_cmd_port "$@" ;;
    sys) __rec_cmd_sys "$@" ;;
    systemd) __rec_cmd_systemd "$@" ;;
    backup) __rec_cmd_backup "$@" ;;
    ip) __rec_cmd_ip "$@" ;;
    whois) __rec_cmd_whois "$@" ;;
    dns) __rec_cmd_dns "$@" ;;
    install) __rec_cmd_install "$@" ;;
    password | passwd | pw) __rec_cmd_password "$@" ;;
    tips) __rec_cmd_tips "$@" ;;
    cheat) __rec_cmd_cheat "$@" ;;
    uninstall) __rec_cmd_uninstall "$@" ;;
    help | --help | -h) __rec_cmd_help ;;
    *)
      rec_ui_err "unknown command \"$_rc_cmd\""
      printf '\n' >&2
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
  _rcv_sub="$REC_SHELL_NAME on $REC_OS"
  [ -n "$_rcv_sha" ] && _rcv_sub="$_rcv_sub ($_rcv_sha)"
  rec_banner "$_rcv_ver" "$_rcv_sub"
  unset _rcv_ver _rcv_sha _rcv_sub
}

__rec_cmd_check() {
  rec_have curl || {
    rec_ui_err 'curl is required for update checks'
    return 1
  }
  _rcc_installed="$(rec_installed_version 2>/dev/null || echo '?')"
  _rcc_latest="$(rec_update_fetch_latest)" || _rcc_latest=""
  if [ -z "$_rcc_latest" ]; then
    rec_ui_err 'could not reach the update server.'
    return 1
  fi
  command mkdir -p "$REC_CACHE_DIR" 2>/dev/null \
    && printf '%s\n%s\n' "$(date +%s)" "$_rcc_latest" >"$REC_CACHE_FILE" 2>/dev/null
  if rec_semver_gt "$_rcc_latest" "$_rcc_installed"; then
    rec_ui_warn_out "rec-shell $_rcc_latest is available (you have $_rcc_installed)."
    rec_ui_step 'run: rec update'
  else
    rec_ui_ok "rec-shell is up to date ($_rcc_installed)."
  fi
}

__rec_cmd_update() {
  rec_have git || {
    rec_ui_err 'git is required to update'
    return 1
  }
  [ -d "$REC_SHELL_DIR/.git" ] || {
    rec_ui_err "$REC_SHELL_DIR is not a git checkout; reinstall with the installer."
    return 1
  }

  _rcu_sudo=no
  if [ ! -w "$REC_SHELL_DIR/.git" ]; then
    if rec_have sudo; then
      _rcu_sudo=yes
      rec_ui_info 'system install detected; using sudo...'
    else
      rec_ui_err "need write access to $REC_SHELL_DIR (run as root)"
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

  _rcu_old="$(rec_installed_version 2>/dev/null || echo '?')"

  __rec_git fetch --tags --prune origin || {
    rec_ui_err 'fetch failed (offline?)'
    return 1
  }

  # Pick the highest SEMVER tag (robust and deterministic; matches
  # scripts/release.sh and `rec git release`). The older "newest tag by commit
  # date" heuristic could pick the wrong tag when commit times were close.
  # Fall back to a fast-forward pull when there are no version tags.
  _rcu_tag="$(__rec_git tag --list 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null | sort -V | tail -n1)"
  if [ -n "$_rcu_tag" ]; then
    __rec_git checkout -q "$_rcu_tag" 2>/dev/null || __rec_git pull --ff-only 2>/dev/null || {
      rec_ui_err 'update failed'
      return 1
    }
  else
    __rec_git pull --ff-only || {
      rec_ui_err 'update failed'
      return 1
    }
  fi

  _rcu_new="$(rec_installed_version 2>/dev/null || echo '?')"
  command mkdir -p "$REC_CACHE_DIR" 2>/dev/null \
    && printf '%s\n%s\n' "$(date +%s)" "$_rcu_new" >"$REC_CACHE_FILE" 2>/dev/null

  if [ "$_rcu_new" = "$_rcu_old" ]; then
    rec_ui_ok "rec-shell is already up to date ($_rcu_new)."
    return 0
  fi
  rec_ui_ok "rec-shell updated: $_rcu_old $REC_UI_G_ARROW $_rcu_new."
  # `rec` is a function in the live shell, so apply the update immediately.
  __rec_cmd_reload
  rec_banner "$_rcu_new" "updated from $_rcu_old" "rec doctor"

  # Soft nudge: if any modern CLI tools are missing, mention rec install once.
  # This deliberately runs only when the version actually changed — quiet on
  # the "already up to date" path.
  if command -v rec_tools_count_missing >/dev/null 2>&1; then
    _rcu_missing="$(rec_tools_count_missing 2>/dev/null)"
    case "$_rcu_missing" in
      '' | 0) ;;
      *)
        rec_ui_note "$_rcu_missing modern CLI tools available — run: rec install"
        ;;
    esac
    unset _rcu_missing
  fi
}

__rec_cmd_reload() {
  unset REC_SHELL_LOADED
  . "$REC_SHELL_DIR/rec-shell.sh"
  # The CLI groups are lazy-loaded and cached on first use; drop them so the
  # next `rec ...` re-sources the freshly updated code instead of the stale
  # functions still in memory (otherwise `rec update` wouldn't take effect).
  unset -f __rec_dispatch __rec_git_dispatch __rec_ssh_dispatch 2>/dev/null
  rec_ui_ok "rec-shell reloaded ($(rec_installed_version 2>/dev/null || echo '?'))."
}

__rec_cmd_doctor() {
  rec_ui_heading 'rec-shell doctor'
  rec_ui_kv version "$(rec_installed_version 2>/dev/null || echo '?')"
  rec_ui_kv shell "$REC_SHELL_NAME"
  rec_ui_kv os "$REC_OS"
  rec_ui_kv dir "$REC_SHELL_DIR"
  rec_ui_kv config "$REC_CONFIG_FILE"
  [ -n "${REC_DISABLED_MODULES:-}" ] && rec_ui_kv disabled "$REC_DISABLED_MODULES"
  printf '\n'

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
  printf '\n'
  __rec_doctor_tools
}

# doctor tools section — one line per modern CLI tool, ✓/✗, and a note for
# bash users that two zsh-only plugins are skipped.
__rec_doctor_tools() {
  rec_ui_heading "tools"
  if command -v rec_tools_catalog >/dev/null 2>&1; then
    rec_tools_catalog | while IFS='|' read -r _rdt_name _rdt_bin _rdt_kind _rdt_pkgs _rdt_desc; do
      [ -z "$_rdt_name" ] && continue
      case "$_rdt_kind" in
        zsh-plugin) continue ;;
      esac
      if rec_tools_present "$_rdt_name"; then
        __rec_ok "$_rdt_name present"
      else
        __rec_no "$_rdt_name missing"
      fi
    done
  fi
  # zsh plugins (kept separate so they only show on zsh and use a different
  # presence check — the catalog's rec_tools_present already does the right
  # thing on both shells, but we surface them in their own block for clarity).
  if [ "$REC_SHELL_NAME" = zsh ]; then
    for _rdt_p in zsh-autosuggestions zsh-syntax-highlighting; do
      if rec_tools_present "$_rdt_p"; then
        __rec_ok "$_rdt_p present"
      else
        __rec_no "$_rdt_p missing"
      fi
    done
  else
    rec_ui_note "zsh-autosuggestions and zsh-syntax-highlighting are zsh-only"
  fi
  unset _rdt_name _rdt_bin _rdt_kind _rdt_pkgs _rdt_desc _rdt_p
}

# doctor status lines: ok on stdout, warnings on stdout too (diagnostics are
# expected on stdout, e.g. `rec doctor | less`).
__rec_ok() { rec_ui_ok "$1"; }
__rec_no() { rec_ui_warn_out "$1"; }

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
# With no module name, open an interactive multiselect picker on a terminal;
# otherwise keep the original single-module behavior.
__rec_cmd_toggle() {
  _rct_action="$1"
  _rct_mod="${2:-}"
  if [ -z "$_rct_mod" ]; then
    if rec_ui_interactive_load && __rec_ui_interactive; then
      __rec_toggle_interactive "$_rct_action"
      return $?
    fi
    rec_ui_err "usage: rec $_rct_action <module>"
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
  rec_ui_ok "${_rct_action}d \"$_rct_mod\". Run: rec reload"
}

# __rec_toggle_interactive ACTION -> pick modules to enable/disable via a
# multiselect, then persist the new REC_DISABLED_MODULES. ACTION is enable|disable.
__rec_toggle_interactive() {
  _rti_action="$1"
  command mkdir -p "$REC_CONFIG_DIR" 2>/dev/null
  _rti_cur="$(
    [ -r "$REC_CONFIG_FILE" ] && . "$REC_CONFIG_FILE" 2>/dev/null
    printf '%s' "${REC_DISABLED_MODULES:-}"
  )"
  _rti_disabled=" $_rti_cur "

  # Candidates: for `disable`, the enabled modules; for `enable`, the disabled.
  _rti_candidates=""
  for _rti_f in "$REC_SHELL_DIR"/modules/*.sh; do
    [ -r "$_rti_f" ] || continue
    _rti_k="${_rti_f##*/}"
    _rti_k="${_rti_k%.sh}"
    _rti_k="${_rti_k#[0-9][0-9]-}"
    case "$_rti_disabled" in
      *" $_rti_k "*) _rti_is=disabled ;;
      *) _rti_is=enabled ;;
    esac
    if [ "$_rti_action" = disable ] && [ "$_rti_is" = enabled ]; then
      _rti_candidates="$_rti_candidates $_rti_k"
    elif [ "$_rti_action" = enable ] && [ "$_rti_is" = disabled ]; then
      _rti_candidates="$_rti_candidates $_rti_k"
    fi
  done
  _rti_candidates="${_rti_candidates# }"

  if [ -z "$_rti_candidates" ]; then
    if [ "$_rti_action" = disable ]; then
      rec_ui_info 'All modules are already enabled.'
    else
      rec_ui_info 'No disabled modules to enable.'
    fi
    return 0
  fi

  # zsh keeps unquoted vars un-split; enable sh-style splitting just here.
  if [ -n "${ZSH_VERSION:-}" ]; then
    setopt local_options sh_word_split 2>/dev/null
  fi
  # shellcheck disable=SC2086 # intentional word-split of the candidate list
  rec_ui_multiselect "Modules to $_rti_action" $_rti_candidates >/dev/null
  if [ -z "${REC_UI_REPLY:-}" ]; then
    rec_ui_info 'Nothing selected.'
    return 0
  fi

  _rti_new=" $_rti_cur "
  # shellcheck disable=SC2086 # REC_UI_REPLY is a space-separated module list
  for _rti_p in $REC_UI_REPLY; do
    if [ "$_rti_action" = disable ]; then
      case "$_rti_new" in
        *" $_rti_p "*) ;;
        *) _rti_new="$_rti_new$_rti_p " ;;
      esac
    else
      _rti_new="$(printf '%s' "$_rti_new" | sed "s/ $_rti_p / /g")"
    fi
  done
  _rti_new="$(printf '%s' "$_rti_new" | sed 's/^ *//; s/  */ /g; s/ *$//')"

  __rec_config_set REC_DISABLED_MODULES "$_rti_new"
  rec_ui_ok "${_rti_action}d: $REC_UI_REPLY. Run: rec reload"
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
      rec_ui_err 'git commands unavailable (missing lib/cli-git.sh)'
      return 1
    fi
  fi
  __rec_git_dispatch "$@"
}

# ssh command group, lazy-loaded from lib/cli-ssh.sh on first use.
__rec_cmd_ssh() {
  if ! command -v __rec_ssh_dispatch >/dev/null 2>&1; then
    if [ -r "$REC_SHELL_DIR/lib/cli-ssh.sh" ]; then
      . "$REC_SHELL_DIR/lib/cli-ssh.sh"
    else
      rec_ui_err 'ssh commands unavailable (missing lib/cli-ssh.sh)'
      return 1
    fi
  fi
  __rec_ssh_dispatch "$@"
}

# Generic lazy-loader factory: source lib/cli-$1.sh if its dispatch is missing,
# then call __rec_$1_dispatch with the remaining args.
__rec_cmd_port() {
  if ! command -v __rec_port_dispatch >/dev/null 2>&1; then
    if [ -r "$REC_SHELL_DIR/lib/cli-port.sh" ]; then
      . "$REC_SHELL_DIR/lib/cli-port.sh"
    else
      rec_ui_err 'port commands unavailable (missing lib/cli-port.sh)'
      return 1
    fi
  fi
  __rec_port_dispatch "$@"
}

__rec_cmd_sys() {
  if ! command -v __rec_sys_dispatch >/dev/null 2>&1; then
    if [ -r "$REC_SHELL_DIR/lib/cli-sys.sh" ]; then
      . "$REC_SHELL_DIR/lib/cli-sys.sh"
    else
      rec_ui_err 'sys commands unavailable (missing lib/cli-sys.sh)'
      return 1
    fi
  fi
  __rec_sys_dispatch "$@"
}

__rec_cmd_systemd() {
  if ! command -v __rec_systemd_dispatch >/dev/null 2>&1; then
    if [ -r "$REC_SHELL_DIR/lib/cli-systemd.sh" ]; then
      . "$REC_SHELL_DIR/lib/cli-systemd.sh"
    else
      rec_ui_err 'systemd commands unavailable (missing lib/cli-systemd.sh)'
      return 1
    fi
  fi
  __rec_systemd_dispatch "$@"
}

__rec_cmd_backup() {
  if ! command -v __rec_backup_dispatch >/dev/null 2>&1; then
    if [ -r "$REC_SHELL_DIR/lib/cli-backup.sh" ]; then
      . "$REC_SHELL_DIR/lib/cli-backup.sh"
    else
      rec_ui_err 'backup commands unavailable (missing lib/cli-backup.sh)'
      return 1
    fi
  fi
  __rec_backup_dispatch "$@"
}

__rec_cmd_ip() {
  if ! command -v __rec_ip_dispatch >/dev/null 2>&1; then
    if [ -r "$REC_SHELL_DIR/lib/cli-ip.sh" ]; then
      . "$REC_SHELL_DIR/lib/cli-ip.sh"
    else
      rec_ui_err 'ip commands unavailable (missing lib/cli-ip.sh)'
      return 1
    fi
  fi
  __rec_ip_dispatch "$@"
}

__rec_cmd_password() {
  if ! command -v __rec_password_dispatch >/dev/null 2>&1; then
    if [ -r "$REC_SHELL_DIR/lib/cli-password.sh" ]; then
      . "$REC_SHELL_DIR/lib/cli-password.sh"
    else
      rec_ui_err 'password command unavailable (missing lib/cli-password.sh)'
      return 1
    fi
  fi
  __rec_password_dispatch "$@"
}

__rec_cmd_whois() {
  if ! command -v __rec_whois_dispatch >/dev/null 2>&1; then
    if [ -r "$REC_SHELL_DIR/lib/cli-whois.sh" ]; then
      . "$REC_SHELL_DIR/lib/cli-whois.sh"
    else
      rec_ui_err 'whois commands unavailable (missing lib/cli-whois.sh)'
      return 1
    fi
  fi
  __rec_whois_dispatch "$@"
}

__rec_cmd_dns() {
  if ! command -v __rec_dns_dispatch >/dev/null 2>&1; then
    if [ -r "$REC_SHELL_DIR/lib/cli-dns.sh" ]; then
      . "$REC_SHELL_DIR/lib/cli-dns.sh"
    else
      rec_ui_err 'dns commands unavailable (missing lib/cli-dns.sh)'
      return 1
    fi
  fi
  __rec_dns_dispatch "$@"
}

__rec_cmd_install() {
  if ! command -v __rec_install_dispatch >/dev/null 2>&1; then
    if [ -r "$REC_SHELL_DIR/lib/cli-install.sh" ]; then
      . "$REC_SHELL_DIR/lib/cli-install.sh"
    else
      rec_ui_err 'install commands unavailable (missing lib/cli-install.sh)'
      return 1
    fi
  fi
  __rec_install_dispatch "$@"
}

# tips and cheat share lib/cli-tips.sh.
__rec_cmd_tips() {
  if ! command -v __rec_tips_dispatch >/dev/null 2>&1; then
    if [ -r "$REC_SHELL_DIR/lib/cli-tips.sh" ]; then
      . "$REC_SHELL_DIR/lib/cli-tips.sh"
    else
      rec_ui_err 'tips unavailable (missing lib/cli-tips.sh)'
      return 1
    fi
  fi
  __rec_tips_dispatch "$@"
}

__rec_cmd_cheat() {
  if ! command -v __rec_cheat_dispatch >/dev/null 2>&1; then
    if [ -r "$REC_SHELL_DIR/lib/cli-tips.sh" ]; then
      . "$REC_SHELL_DIR/lib/cli-tips.sh"
    else
      rec_ui_err 'cheat unavailable (missing lib/cli-tips.sh)'
      return 1
    fi
  fi
  __rec_cheat_dispatch "$@"
}

__rec_cmd_uninstall() {
  if [ -r "$REC_SHELL_DIR/uninstall.sh" ]; then
    sh "$REC_SHELL_DIR/uninstall.sh" "$@"
  else
    rec_ui_err "uninstaller not found at $REC_SHELL_DIR/uninstall.sh"
    return 1
  fi
}

__rec_cmd_help() {
  __rec_ui_emit 1 "$REC_UI_S_BOLD" "rec-shell"
  printf ' '
  __rec_ui_emit 1 "$REC_UI_S_CYAN" "$(rec_installed_version 2>/dev/null || echo '?')"
  printf '\n'
  __rec_ui_emit 1 "$REC_UI_S_DIM" "modern bash & zsh configuration"
  printf '\n\n'
  __rec_ui_emit 1 "$REC_UI_S_DIM" "Usage:"
  printf ' rec <command>'
  __rec_ui_emit 1 "$REC_UI_S_DIM" "   (rec-shell also works)"
  printf '\n\n'
  __rec_ui_emit 1 "$REC_UI_S_BOLD" "Commands"
  printf '\n'
  __rec_help_row "update" "Update to the latest released version (newest tag)"
  __rec_help_row "check" "Check now whether a newer version is available"
  __rec_help_row "version" "Show installed version, commit and shell/OS"
  __rec_help_row "reload" "Re-source rec-shell in the current shell"
  __rec_help_row "doctor" "Diagnose the installation"
  __rec_help_row "git <command>" "Git helpers: sync, push, release, init"
  __rec_help_row "ssh [alias]" "SSH host picker; add/fav/edit (no arg: picker)"
  __rec_help_row "port [command]" "Listening ports: list (default), kill, free"
  __rec_help_row "sys [command]" "Server diagnostics: overview, disk, mem, top, ports, uptime"
  __rec_help_row "systemd <cmd>" "systemctl wrapper with smart sudo (Linux only)"
  __rec_help_row "backup <cmd>" "Directory snapshots: create, list, restore, prune"
  __rec_help_row "ip [command]" "IP address: public (default), local, all"
  __rec_help_row "whois <target>" "Whois lookup for a domain or IP (+geo, PTR)"
  __rec_help_row "dns <domain>" "DNS records: A, AAAA, MX, NS, TXT, CNAME, SOA"
  __rec_help_row "install [tool]" "Install modern CLI tools (interactive picker)"
  __rec_help_row "password" "Strong password generator (-> clipboard)"
  __rec_help_row "tips [next|all]" "One reminder for the modern CLI tools you have"
  __rec_help_row "cheat [tool]" "Cheatsheet for installed tools (rg/fd/eza/bat/...)"
  __rec_help_row "enable [module]" "Re-enable a module (no arg: interactive picker)"
  __rec_help_row "disable [module]" "Disable a module (no arg: interactive picker)"
  __rec_help_row "uninstall" "Remove rec-shell (--purge also removes config)"
  __rec_help_row "help" "Show this help"
}

# __rec_help_row NAME DESCRIPTION -> a command name (accent) + its description.
__rec_help_row() {
  printf '  '
  __rec_ui_emit 1 "$REC_UI_S_CYAN" "$(printf '%-18s' "$1")"
  printf ' %s\n' "$2"
}

# Bare `rec` on a terminal: an interactive command picker (arrows + enter).
# Non-interactive (scripts, pipes): fall back to the textual help.
__rec_cmd_menu() {
  if ! rec_ui_interactive_load || ! __rec_ui_interactive; then
    __rec_cmd_help
    return 0
  fi
  _rcm_choice="$(rec_ui_select 'Pick a command' \
    'doctor    - diagnose the installation' \
    'version   - show version, commit, shell/OS' \
    'check     - check for a newer version' \
    'update    - update to the latest release' \
    'reload    - re-source rec-shell' \
    'git       - git helpers (sync/push/release/init)' \
    'ssh       - SSH host picker (connect/add/favorite)' \
    'port      - listening ports (list/kill/free)' \
    'sys       - server diagnostics (overview/disk/mem/top)' \
    'systemd   - systemctl wrapper (Linux only)' \
    'backup    - directory snapshots (create/list/restore)' \
    'ip        - IP address (public/local/all)' \
    'whois     - whois lookup (domain or IP)' \
    'dns       - DNS records (A/AAAA/MX/NS/TXT/CNAME/SOA)' \
    'install   - install modern CLI tools (interactive picker)' \
    'password  - strong password generator' \
    'tips      - one reminder for the CLI tools you have' \
    'cheat     - cheatsheet for installed tools' \
    'enable    - re-enable a module (picker)' \
    'disable   - disable a module (picker)' \
    'help      - show full help')"
  [ -n "$_rcm_choice" ] || return 0
  _rcm_cmd="${_rcm_choice%% *}"
  __rec_dispatch "$_rcm_cmd"
}
