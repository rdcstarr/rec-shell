# shellcheck shell=bash
#
# lib/cli-systemd.sh — the `rec systemd` command group. Linux-only wrapper
# around systemctl + journalctl that auto-prefixes sudo for state-changing
# verbs and refuses to run on non-Linux hosts with a clear message.
#
#   rec systemd status <unit>           (default verb when nothing else matches)
#   rec systemd start|stop|restart|reload <unit>
#   rec systemd enable|disable <unit>
#   rec systemd logs <unit> [--tail N] [--follow]
#   rec systemd list [--all]

__rec_systemd_dispatch() {
  if [ "$REC_OS" != linux ]; then
    rec_ui_err "rec systemd is Linux-only (this host: $REC_OS)"
    return 1
  fi
  if ! rec_have systemctl; then
    rec_ui_err "'systemctl' not found on this host"
    return 1
  fi
  _rsd_cmd="${1:-help}"
  [ $# -gt 0 ] && shift
  case "$_rsd_cmd" in
    status) __rec_systemd_status "$@" ;;
    start | stop | restart | reload | enable | disable) __rec_systemd_state "$_rsd_cmd" "$@" ;;
    logs) __rec_systemd_logs "$@" ;;
    list) __rec_systemd_list "$@" ;;
    help | --help | -h) __rec_systemd_help ;;
    *)
      rec_ui_err "rec systemd: unknown command \"$_rsd_cmd\""
      printf '\n' >&2
      __rec_systemd_help >&2
      return 2
      ;;
  esac
}

__rec_systemd_help() {
  cat <<'EOF'
rec systemd — quick systemctl + journalctl wrapper (Linux only)

Usage: rec systemd <command> [args]

Commands:
  status <unit>                       systemctl status <unit>
  start|stop|restart|reload <unit>    state changes (auto-sudo when not root)
  enable|disable <unit>               unit enablement (auto-sudo when not root)
  logs <unit> [--tail N] [--follow]   journalctl -u <unit> with these flags
  list [--all]                        list active services (--all: include inactive)

Notes:
  State-changing verbs auto-prefix sudo when you aren't root. Read-only verbs
  (status, logs, list) never escalate. Use --no-sudo to disable auto-sudo
  on a state-change call.
EOF
}

# Echo "sudo" when we need it for state changes, "" otherwise. Honors --no-sudo.
__rec_systemd_sudo_prefix() {
  local no_sudo="$1"
  [ "$no_sudo" = yes ] && return 0
  [ "$(id -u)" -eq 0 ] && return 0
  if rec_have sudo; then
    printf 'sudo'
  else
    rec_ui_err "this verb needs root and 'sudo' is unavailable"
    return 1
  fi
}

__rec_systemd_status() {
  local unit="" arg
  for arg in "$@"; do
    case "$arg" in
      -h | --help)
        printf 'Usage: rec systemd status <unit>\n'
        return 0
        ;;
      -*)
        rec_ui_err "rec systemd status: unknown flag '$arg'"
        return 2
        ;;
      *) [ -z "$unit" ] && unit="$arg" ;;
    esac
  done
  if [ -z "$unit" ]; then
    rec_ui_err "rec systemd status: <unit> is required"
    return 2
  fi
  systemctl status -- "$unit"
}

# Shared implementation for start/stop/restart/reload/enable/disable.
__rec_systemd_state() {
  local verb="$1"
  shift
  local unit="" NO_SUDO=no arg
  for arg in "$@"; do
    case "$arg" in
      -h | --help)
        printf 'Usage: rec systemd %s <unit> [--no-sudo]\n' "$verb"
        return 0
        ;;
      --no-sudo) NO_SUDO=yes ;;
      -*)
        rec_ui_err "rec systemd $verb: unknown flag '$arg'"
        return 2
        ;;
      *) [ -z "$unit" ] && unit="$arg" ;;
    esac
  done
  if [ -z "$unit" ]; then
    rec_ui_err "rec systemd $verb: <unit> is required"
    return 2
  fi
  local sudo_prefix
  sudo_prefix="$(__rec_systemd_sudo_prefix "$NO_SUDO")" || return $?
  if [ -n "$sudo_prefix" ]; then
    rec_ui_info "using sudo"
  fi
  $sudo_prefix systemctl "$verb" -- "$unit"
}

__rec_systemd_logs() {
  local unit="" TAIL="" FOLLOW=no arg
  for arg in "$@"; do
    case "$arg" in
      -h | --help)
        cat <<'EOF'
Usage: rec systemd logs <unit> [--tail N] [--follow]

Show journal entries for <unit>. --tail N caps the number of lines (default:
500 if --follow is not set). --follow streams new entries.
EOF
        return 0
        ;;
      --tail=*) TAIL="${arg#*=}" ;;
      --tail)
        # Next arg is the value; handled by the next iteration.
        TAIL=NEXT
        ;;
      -f | --follow) FOLLOW=yes ;;
      -*)
        rec_ui_err "rec systemd logs: unknown flag '$arg'"
        return 2
        ;;
      *)
        if [ "$TAIL" = NEXT ]; then
          TAIL="$arg"
        elif [ -z "$unit" ]; then
          unit="$arg"
        else
          rec_ui_err "rec systemd logs: extra argument '$arg'"
          return 2
        fi
        ;;
    esac
  done
  [ "$TAIL" = NEXT ] && {
    rec_ui_err "--tail requires a value"
    return 2
  }
  if [ -z "$unit" ]; then
    rec_ui_err "rec systemd logs: <unit> is required"
    return 2
  fi
  case "$TAIL" in
    '') [ "$FOLLOW" = yes ] || TAIL=500 ;;
    *[!0-9]*)
      rec_ui_err "--tail '$TAIL' is not a number"
      return 2
      ;;
  esac
  local flags="-u $unit"
  [ -n "$TAIL" ] && flags="$flags -n $TAIL"
  [ "$FOLLOW" = yes ] && flags="$flags -f"
  # shellcheck disable=SC2086 # we want the flags to word-split here
  journalctl $flags
}

__rec_systemd_list() {
  local ALL=no arg
  for arg in "$@"; do
    case "$arg" in
      -h | --help)
        printf 'Usage: rec systemd list [--all]\n'
        return 0
        ;;
      --all) ALL=yes ;;
      -*)
        rec_ui_err "rec systemd list: unknown flag '$arg'"
        return 2
        ;;
    esac
  done
  if [ "$ALL" = yes ]; then
    systemctl list-units --type=service --all
  else
    systemctl list-units --type=service
  fi
}
