# shellcheck shell=bash
#
# lib/cli-ip.sh — the `rec ip` command group. Quick public + local IP lookup
# with no setup. Lazy-loaded by lib/cli.sh on the first `rec ip ...`.
#
#   rec ip         public IP via HTTPS (3 providers tried in order)
#   rec ip local   primary outbound IPv4 of this host
#   rec ip all     all interfaces with addresses
#   rec ip client  client IP: SSH_CONNECTION when in SSH, else the local outbound IP

__rec_ip_dispatch() {
  _ri_cmd="${1:-public}"
  [ $# -gt 0 ] && shift
  case "$_ri_cmd" in
    public) __rec_ip_public "$@" ;;
    local) __rec_ip_local "$@" ;;
    all) __rec_ip_all "$@" ;;
    client) __rec_ip_client "$@" ;;
    help | --help | -h) __rec_ip_help ;;
    *)
      rec_ui_err "rec ip: unknown command \"$_ri_cmd\""
      printf '\n' >&2
      __rec_ip_help >&2
      return 2
      ;;
  esac
}

__rec_ip_help() {
  cat <<'EOF'
rec ip — IP address utility

Usage: rec ip [<command>]

Commands:
  (none) / public   Public IP via HTTPS (tries ifconfig.co, ipify, ipinfo).
  local             Primary outbound IPv4 of this host.
  all               All network interfaces with their IPv4 addresses.
  client            Client-side IP: SSH_CONNECTION/SSH_CLIENT when in an SSH session,
                    otherwise the local outbound IPv4 (same as `rec ip local`).

Examples:
  rec ip
  rec ip local
  rec ip all
  rec ip client
EOF
}

__rec_ip_public() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -h | --help)
        printf 'Usage: rec ip [public]\n'
        return 0
        ;;
      *)
        rec_ui_err "rec ip public: unexpected arg '$arg'"
        return 2
        ;;
    esac
  done
  if ! rec_have curl; then
    rec_ui_err "'curl' is required for public IP lookup"
    return 1
  fi
  local provider ip
  for provider in https://ifconfig.co https://api.ipify.org https://ipinfo.io/ip; do
    ip="$(curl -fsS --max-time 5 "$provider" 2>/dev/null | tr -d '\r\n[:space:]')"
    case "$ip" in
      *.*.*.* | *:*:*)
        printf '%s\n' "$ip"
        return 0
        ;;
    esac
  done
  rec_ui_err "could not reach any public-IP provider"
  return 1
}

__rec_ip_local() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -h | --help)
        printf 'Usage: rec ip local\n'
        return 0
        ;;
      *)
        rec_ui_err "rec ip local: unexpected arg '$arg'"
        return 2
        ;;
    esac
  done
  local ip iface
  case "$REC_OS" in
    linux)
      if rec_have ip; then
        ip="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i = 1; i <= NF; i++) if ($i == "src") print $(i + 1)}')"
      fi
      if [ -z "$ip" ] && rec_have hostname; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
      fi
      ;;
    mac)
      if rec_have route; then
        iface="$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')"
      fi
      if [ -n "$iface" ] && rec_have ipconfig; then
        ip="$(ipconfig getifaddr "$iface" 2>/dev/null)"
      fi
      ;;
  esac
  if [ -z "$ip" ]; then
    rec_ui_err "could not determine local IP"
    return 1
  fi
  printf '%s\n' "$ip"
}

__rec_ip_client() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -h | --help)
        printf 'Usage: rec ip client\n'
        return 0
        ;;
      *)
        rec_ui_err "rec ip client: unexpected arg '$arg'"
        return 2
        ;;
    esac
  done
  local src="$SSH_CONNECTION"
  [ -z "$src" ] && src="$SSH_CLIENT"
  if [ -n "$src" ]; then
    printf '%s\n' "${src%% *}"
    return 0
  fi
  __rec_ip_local
}

__rec_ip_all() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -h | --help)
        printf 'Usage: rec ip all\n'
        return 0
        ;;
      *)
        rec_ui_err "rec ip all: unexpected arg '$arg'"
        return 2
        ;;
    esac
  done
  case "$REC_OS" in
    linux)
      if rec_have ip; then
        ip -br -4 addr 2>/dev/null
      elif rec_have ifconfig; then
        ifconfig 2>/dev/null | awk '/^[a-z0-9]/ {iface=$1; sub(/:$/, "", iface)} /inet / {print iface, $2}'
      else
        rec_ui_err "neither 'ip' nor 'ifconfig' is available"
        return 1
      fi
      ;;
    mac)
      if rec_have ifconfig; then
        ifconfig 2>/dev/null | awk '/^[a-z0-9]/ {iface=$1; sub(/:$/, "", iface)} /inet / {print iface, $2}'
      else
        rec_ui_err "'ifconfig' not found"
        return 1
      fi
      ;;
    *)
      rec_ui_err "rec ip all: unsupported OS ($REC_OS)"
      return 1
      ;;
  esac
}
