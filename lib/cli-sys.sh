# shellcheck shell=bash
#
# lib/cli-sys.sh — the `rec sys` command group. Quick server diagnostics that
# behave the same on Linux and macOS (with platform-specific implementations
# under the hood). Lazy-loaded by lib/cli.sh on the first `rec sys ...`.
#
#   rec sys              one-screen overview
#   rec sys disk [PATH]  disk usage (df + top dirs)
#   rec sys mem          memory breakdown
#   rec sys top [N]      top processes by CPU then RSS
#   rec sys ports        delegates to `rec port list`
#   rec sys uptime       uptime + load

__rec_sys_dispatch() {
  _rs_cmd="${1:-overview}"
  [ $# -gt 0 ] && shift
  case "$_rs_cmd" in
    overview) __rec_sys_overview "$@" ;;
    disk) __rec_sys_disk "$@" ;;
    mem | memory) __rec_sys_mem "$@" ;;
    top) __rec_sys_top "$@" ;;
    ports) __rec_sys_ports "$@" ;;
    uptime) __rec_sys_uptime "$@" ;;
    help | --help | -h) __rec_sys_help ;;
    *)
      rec_ui_err "rec sys: unknown command \"$_rs_cmd\""
      printf '\n' >&2
      __rec_sys_help >&2
      return 2
      ;;
  esac
}

__rec_sys_help() {
  cat <<'EOF'
rec sys — quick server diagnostics

Usage: rec sys [<command> [args]]

Commands:
  (none)           One-screen overview: uptime, load, mem%, root disk%, ports
  disk [PATH]      df -h + top 10 largest items under PATH (default: $PWD)
  mem              Memory breakdown (free -h on Linux, vm_stat on macOS)
  top [N]          Top N processes by CPU, then by RSS (default N = 10)
  ports            Listening TCP/UDP ports (alias for `rec port list`)
  uptime           Uptime + load

Examples:
  rec sys
  rec sys disk /var
  rec sys top 5
EOF
}

# --- overview -----------------------------------------------------------

# Internal: percent disk used on /, no trailing %. Empty on failure.
__rec_sys_root_disk_pct() {
  df -P / 2>/dev/null | awk 'NR == 2 { sub(/%/, "", $5); print $5 }'
}

# Internal: percent memory used (rough; mac uses page stats, linux uses free).
__rec_sys_mem_pct() {
  case "$REC_OS" in
    linux)
      free 2>/dev/null | awk '/^Mem:/ { if ($2 > 0) printf "%d", ($3 / $2) * 100 }'
      ;;
    mac)
      # Sum the pages and compute (active+wired+compressed)/total.
      vm_stat 2>/dev/null | awk '
        /page size of/ { ps = $8 }
        /Pages free/             { free = $3 }
        /Pages active/           { active = $3 }
        /Pages inactive/         { inact = $3 }
        /Pages speculative/      { spec = $3 }
        /Pages wired down/       { wired = $4 }
        /Pages occupied by compressor/ { comp = $5 }
        END {
          gsub(/\./, "", free); gsub(/\./, "", active); gsub(/\./, "", inact)
          gsub(/\./, "", spec); gsub(/\./, "", wired); gsub(/\./, "", comp)
          total = free + active + inact + spec + wired + comp
          if (total > 0) printf "%d", ((active + wired + comp) / total) * 100
        }'
      ;;
  esac
}

# Internal: count of distinct listening ports.
__rec_sys_port_count() {
  case "$REC_OS" in
    linux) rec_have ss && ss -Htln 2>/dev/null | wc -l | awk '{print $1}' ;;
    mac) rec_have lsof && lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR > 1' | wc -l | awk '{print $1}' ;;
  esac
}

__rec_sys_overview() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -h | --help)
        cat <<'EOF'
Usage: rec sys

One-screen overview: hostname, uptime, load, mem usage, root disk usage,
and listening port count.
EOF
        return 0
        ;;
    esac
  done

  local host up load mem disk ports
  host="$(uname -n 2>/dev/null)"
  case "$REC_OS" in
    linux) up="$(uptime -p 2>/dev/null || uptime)" ;;
    mac) up="$(uptime)" ;;
    *) up="$(uptime 2>/dev/null)" ;;
  esac
  load="$(uptime 2>/dev/null | awk -F'load average[s]*:[[:space:]]*' '{print $2}')"
  mem="$(__rec_sys_mem_pct)"
  disk="$(__rec_sys_root_disk_pct)"
  ports="$(__rec_sys_port_count)"

  rec_ui_heading "system"
  rec_ui_kv "host" "${host:-?}"
  rec_ui_kv "os" "$REC_OS ($(uname -sr 2>/dev/null))"
  rec_ui_kv "uptime" "${up:-?}"
  [ -n "$load" ] && rec_ui_kv "load" "$load"
  [ -n "$mem" ] && rec_ui_kv "mem" "${mem}% used"
  [ -n "$disk" ] && rec_ui_kv "disk /" "${disk}% used"
  [ -n "$ports" ] && rec_ui_kv "ports" "$ports listening"
}

# --- disk ---------------------------------------------------------------

__rec_sys_disk() {
  local path="" arg
  for arg in "$@"; do
    case "$arg" in
      -h | --help)
        cat <<'EOF'
Usage: rec sys disk [PATH]

Show filesystem usage (df -h) and the 10 largest immediate children of PATH
(default: current directory).
EOF
        return 0
        ;;
      *) [ -z "$path" ] && path="$arg" ;;
    esac
  done
  path="${path:-.}"
  if [ ! -d "$path" ]; then
    rec_ui_err "rec sys disk: '$path' is not a directory"
    return 1
  fi

  rec_ui_heading "filesystems"
  df -h 2>/dev/null
  printf '\n'
  rec_ui_heading "top 10 in $path"
  # macOS du lacks GNU --max-depth; emulate with a single-level glob.
  (cd "$path" 2>/dev/null && du -shx -- .[!.]* * 2>/dev/null | sort -h | tail -n 10)
}

# --- mem ----------------------------------------------------------------

__rec_sys_mem() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -h | --help)
        printf 'Usage: rec sys mem\n\nShow memory breakdown.\n'
        return 0
        ;;
    esac
  done
  rec_ui_heading "memory"
  case "$REC_OS" in
    linux)
      if rec_have free; then
        free -h
      else
        rec_ui_err "'free' not found"
        return 1
      fi
      ;;
    mac)
      if rec_have vm_stat; then
        vm_stat
      else
        rec_ui_err "'vm_stat' not found"
        return 1
      fi
      ;;
    *)
      rec_ui_err "rec sys mem: unsupported OS ($REC_OS)"
      return 1
      ;;
  esac
}

# --- top ----------------------------------------------------------------

__rec_sys_top() {
  local n="" arg
  for arg in "$@"; do
    case "$arg" in
      -h | --help)
        printf 'Usage: rec sys top [N]\n\nTop N processes by CPU then RSS (default 10).\n'
        return 0
        ;;
      *[!0-9]*)
        rec_ui_err "rec sys top: '$arg' is not a number"
        return 2
        ;;
      *) n="$arg" ;;
    esac
  done
  n="${n:-10}"

  rec_ui_heading "top $n by CPU"
  # POSIX ps with portable column selection; sort numerically on %CPU desc.
  ps -eo pid,user,pcpu,pmem,comm 2>/dev/null \
    | awk 'NR == 1; NR > 1 { print }' \
    | {
      read -r hdr
      printf '%s\n' "$hdr"
      sort -k3 -rn
    } \
    | head -n $((n + 1))

  printf '\n'
  rec_ui_heading "top $n by RSS"
  ps -eo pid,user,rss,pmem,comm 2>/dev/null \
    | {
      read -r hdr
      printf '%s\n' "$hdr"
      sort -k3 -rn
    } \
    | head -n $((n + 1))
}

# --- ports --------------------------------------------------------------

__rec_sys_ports() {
  # Delegate to `rec port list`. Source on demand so `rec sys ports` works
  # even when `rec port` hasn't been called yet in this shell.
  if ! command -v __rec_port_list >/dev/null 2>&1; then
    if [ -r "$REC_SHELL_DIR/lib/cli-port.sh" ]; then
      . "$REC_SHELL_DIR/lib/cli-port.sh"
    else
      rec_ui_err 'rec sys ports: lib/cli-port.sh is missing'
      return 1
    fi
  fi
  __rec_port_list "$@"
}

# --- uptime -------------------------------------------------------------

__rec_sys_uptime() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -h | --help)
        printf 'Usage: rec sys uptime\n\nShow uptime + load.\n'
        return 0
        ;;
    esac
  done
  case "$REC_OS" in
    linux) uptime -p 2>/dev/null || uptime ;;
    *) uptime ;;
  esac
  # Always print the raw uptime line too — it contains load averages.
  if [ "$REC_OS" = linux ]; then uptime; fi
}
