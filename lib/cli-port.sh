# shellcheck shell=bash
#
# lib/cli-port.sh — the `rec port` command group. Lazy-loaded by lib/cli.sh on
# the first `rec port ...`. Cross-platform listing of listening ports and
# convenient kill / free-check helpers.
#
#   rec port [list]          list listening TCP/UDP ports with PID + process
#   rec port kill <port>     kill the process owning <port> (prompts unless --yes)
#   rec port free <port>     exit 0 if the port is unused, 1 if in use

__rec_port_dispatch() {
  _rp_cmd="${1:-list}"
  [ $# -gt 0 ] && shift
  case "$_rp_cmd" in
    list | ls) __rec_port_list "$@" ;;
    kill) __rec_port_kill "$@" ;;
    free) __rec_port_free "$@" ;;
    help | --help | -h) __rec_port_help ;;
    *)
      rec_ui_err "rec port: unknown command \"$_rp_cmd\""
      printf '\n' >&2
      __rec_port_help >&2
      return 2
      ;;
  esac
}

__rec_port_help() {
  cat <<'EOF'
rec port — listening port manager

Usage: rec port <command> [args]

Commands:
  list                  Show listening TCP/UDP ports with PID + process name
                        (default if no command is given).
  kill <port> [--yes]   Kill the process owning <port>. Prompts to confirm
                        unless --yes is given. Auto-uses sudo if the process
                        is owned by another user. --force escalates to SIGKILL.
  free <port>           Exit 0 if the port is unused, 1 if in use. For scripts.

Examples:
  rec port             # show everything that's listening
  rec port free 3000   # if rec port free 3000; then ...; fi
  rec port kill 3000
EOF
}

# Emit `<proto> <port> <pid> <process>` rows from the platform's tooling.
# Stays POSIX so the caller can pipe / column / awk uniformly.
__rec_port_scan_raw() {
  case "$REC_OS" in
    linux)
      if rec_have ss; then
        # -H: no header, -t: tcp, -u: udp, -l: listening, -n: numeric, -p: process
        ss -Htulnp 2>/dev/null | awk '
          {
            proto = $1
            # local address is column 5 for tcp, column 4 for udp on some ss versions;
            # we read it as the last column before "Peer" — both layouts have the
            # listen address in $5 with at least 6 columns. Fall back to $4 otherwise.
            addr = $5; if (NF < 6) addr = $4
            n = split(addr, a, ":"); port = a[n]
            # users:(("name",pid=1234,fd=5))  -> grab name + pid
            pid = "-"; name = "-"
            for (i = 1; i <= NF; i++) {
              if (match($i, /users:\(\(/)) {
                s = substr($i, RSTART)
                if (match(s, /"[^"]+"/)) name = substr(s, RSTART + 1, RLENGTH - 2)
                if (match(s, /pid=[0-9]+/))  pid  = substr(s, RSTART + 4, RLENGTH - 4)
              }
            }
            printf "%s\t%s\t%s\t%s\n", proto, port, pid, name
          }
        '
      elif rec_have netstat; then
        netstat -tulnp 2>/dev/null | awk '
          /^(tcp|udp)/ && /LISTEN|udp/ {
            proto = $1
            n = split($4, a, ":"); port = a[n]
            pid = "-"; name = "-"
            if ($NF ~ /\//) { split($NF, b, "/"); pid = b[1]; name = b[2] }
            printf "%s\t%s\t%s\t%s\n", proto, port, pid, name
          }
        '
      else
        rec_ui_err "neither 'ss' nor 'netstat' found"
        return 1
      fi
      ;;
    mac)
      if rec_have lsof; then
        # -nP: no DNS / no port-name; -iTCP -sTCP:LISTEN: listening tcp; -iUDP: all udp
        lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 {
          name = $1; pid = $2
          n = split($9, a, ":"); port = a[n]
          printf "tcp\t%s\t%s\t%s\n", port, pid, name
        }'
        lsof -nP -iUDP 2>/dev/null | awk 'NR > 1 {
          name = $1; pid = $2
          n = split($9, a, ":"); port = a[n]
          printf "udp\t%s\t%s\t%s\n", port, pid, name
        }'
      else
        rec_ui_err "'lsof' not found"
        return 1
      fi
      ;;
    *)
      rec_ui_err "rec port: unsupported OS ($REC_OS)"
      return 1
      ;;
  esac
}

__rec_port_list() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -h | --help)
        cat <<'EOF'
Usage: rec port list

Show listening TCP/UDP ports with PID + process name. Output:
  PROTO  PORT   PID    PROCESS
EOF
        return 0
        ;;
    esac
  done

  local raw
  raw="$(__rec_port_scan_raw)" || return $?
  if [ -z "$raw" ]; then
    rec_ui_info 'no listening ports'
    return 0
  fi
  # Header + sorted, deduplicated, columnated output.
  {
    printf 'PROTO\tPORT\tPID\tPROCESS\n'
    printf '%s\n' "$raw" | sort -u -t '	' -k1,1 -k2,2n
  } | column -t -s '	'
}

# Resolve <port> to a single PID (TCP first, then UDP). Echoes the pid; empty
# string means "nothing listening on this port".
__rec_port_pid_for() {
  local port="$1" raw p pid
  raw="$(__rec_port_scan_raw)" || return $?
  printf '%s\n' "$raw" | while IFS='	' read -r _ p pid _; do
    if [ "$p" = "$port" ] && [ "$pid" != "-" ] && [ -n "$pid" ]; then
      printf '%s' "$pid"
      return 0
    fi
  done
}

__rec_port_free() {
  local port="${1:-}"
  if [ -z "$port" ] || [ "$port" = "-h" ] || [ "$port" = "--help" ]; then
    cat <<'EOF'
Usage: rec port free <port>

Exit 0 if nothing is listening on <port>, 1 if something is. Designed for
use in conditional scripts:
  if rec port free 3000; then npm run dev; fi
EOF
    [ -z "$port" ] && return 2 || return 0
  fi
  case "$port" in
    *[!0-9]*)
      rec_ui_err "rec port free: '$port' is not a port number"
      return 2
      ;;
  esac
  local pid
  pid="$(__rec_port_pid_for "$port")"
  if [ -n "$pid" ]; then
    return 1
  fi
  return 0
}

__rec_port_kill() {
  local port="" YES=no FORCE=no arg
  for arg in "$@"; do
    case "$arg" in
      -y | --yes) YES=yes ;;
      -f | --force) FORCE=yes ;;
      -h | --help)
        cat <<'EOF'
Usage: rec port kill <port> [--yes] [--force]

Kill the process listening on <port>. Prompts to confirm unless --yes.
With --force, escalates to SIGKILL when the process doesn't exit cleanly.
Auto-uses sudo when the PID belongs to another user.
EOF
        return 0
        ;;
      -*)
        rec_ui_err "rec port kill: unknown flag '$arg'"
        return 2
        ;;
      *)
        if [ -z "$port" ]; then
          port="$arg"
        else
          rec_ui_err "rec port kill: extra argument '$arg'"
          return 2
        fi
        ;;
    esac
  done
  if [ -z "$port" ]; then
    rec_ui_err "rec port kill: <port> is required"
    return 2
  fi
  case "$port" in
    *[!0-9]*)
      rec_ui_err "rec port kill: '$port' is not a port number"
      return 2
      ;;
  esac

  local pid
  pid="$(__rec_port_pid_for "$port")"
  if [ -z "$pid" ]; then
    rec_ui_info "port $port is not in use"
    return 0
  fi

  local pname
  pname="$(ps -o comm= -p "$pid" 2>/dev/null | head -n1)"
  [ -n "$pname" ] || pname='?'
  rec_ui_step "port $port -> pid $pid ($pname)"

  # sudo if the process owner isn't us and we're not root.
  local owner uid prefix=""
  owner="$(ps -o user= -p "$pid" 2>/dev/null | head -n1 | awk '{print $1}')"
  uid="$(id -un 2>/dev/null)"
  if [ "$(id -u)" -ne 0 ] && [ -n "$owner" ] && [ "$owner" != "$uid" ]; then
    if rec_have sudo; then
      rec_ui_info "process owned by $owner; using sudo"
      prefix="sudo"
    else
      rec_ui_err "process owned by $owner and sudo is unavailable"
      return 1
    fi
  fi

  if [ "$YES" != yes ]; then
    if rec_ui_interactive_load && __rec_ui_interactive; then
      rec_ui_confirm "Kill pid $pid ($pname) on port $port?" no || {
        rec_ui_info aborted
        return 0
      }
    else
      rec_ui_warn "non-interactive; pass --yes to confirm"
      return 1
    fi
  fi

  $prefix kill "$pid" 2>/dev/null || {
    rec_ui_err "failed to send TERM to $pid"
    return 1
  }
  # Give it a moment, then escalate if --force.
  sleep 1
  if kill -0 "$pid" 2>/dev/null; then
    if [ "$FORCE" = yes ]; then
      rec_ui_warn "$pid still alive; sending KILL"
      $prefix kill -9 "$pid" 2>/dev/null || {
        rec_ui_err "failed to send KILL to $pid"
        return 1
      }
    else
      rec_ui_warn "$pid still alive; pass --force for SIGKILL"
      return 1
    fi
  fi
  rec_ui_ok "freed port $port"
}
