# shellcheck shell=bash
#
# lib/cli-password.sh — the `rec password` command. Strong password generator
# that reads from /dev/urandom (falling back to `openssl rand`), filters to a
# safe charset, and optionally copies the result to the system clipboard.
#
#   rec password                       24-char password with specials, copied + printed
#   rec password --length 32 --no-special
#   rec password --count 3
#   rec password --no-copy             skip clipboard

__rec_password_dispatch() {
  __rec_password_run "$@"
}

__rec_password_help() {
  cat <<'EOF'
rec password — strong password generator

Usage: rec password [--length N] [--no-special] [--no-copy] [--count N]

Options:
  --length N      Password length (default 24, min 8, max 256).
  --no-special    Use only A-Z a-z 0-9 (default includes !@#$%^&*-_=+?).
  --no-copy       Do not copy to clipboard (default: copy AND print).
  --count N       Generate N passwords (only the last is copied; default 1).
  -h, --help      Show this help.

Clipboard: pbcopy on macOS; wl-copy or xclip/xsel on Linux. If no clipboard
tool is available, the password is printed only with a warning.
EOF
}

# Read N random characters from the given charset using /dev/urandom + tr.
# Falls back to `openssl rand` if /dev/urandom is unreadable.
__rec_password_generate_one() {
  local n="$1" charset="$2" out=""
  if [ -r /dev/urandom ]; then
    # tr -dc keeps only chars in the set; head -c trims to N bytes.
    out="$(LC_ALL=C tr -dc "$charset" </dev/urandom 2>/dev/null | head -c "$n")"
  fi
  if [ -z "$out" ] && rec_have openssl; then
    # Pull plenty of base64 (which is alnum + /+=); filter to the requested set.
    out="$(openssl rand -base64 $((n * 4)) 2>/dev/null | LC_ALL=C tr -dc "$charset" | head -c "$n")"
  fi
  if [ -z "$out" ] || [ "${#out}" -lt "$n" ]; then
    rec_ui_err "could not gather enough entropy"
    return 1
  fi
  printf '%s' "$out"
}

# Detect a clipboard tool. Echoes the command, or nothing if none works.
__rec_password_clipboard_cmd() {
  case "$REC_OS" in
    mac)
      rec_have pbcopy && {
        printf 'pbcopy'
        return 0
      }
      ;;
    linux)
      # Wayland first, then X11. Only consider X11 when DISPLAY is set; xclip
      # without a display hangs.
      if [ -n "${WAYLAND_DISPLAY:-}" ] && rec_have wl-copy; then
        printf 'wl-copy'
        return 0
      fi
      if [ -n "${DISPLAY:-}" ]; then
        rec_have xclip && {
          printf 'xclip -selection clipboard'
          return 0
        }
        rec_have xsel && {
          printf 'xsel --clipboard --input'
          return 0
        }
      fi
      ;;
  esac
  return 1
}

__rec_password_run() {
  local LENGTH=24 SPECIAL=yes COPY=yes COUNT=1 arg
  while [ $# -gt 0 ]; do
    arg="$1"
    case "$arg" in
      -h | --help)
        __rec_password_help
        return 0
        ;;
      --length=*) LENGTH="${arg#*=}" ;;
      --length)
        shift
        LENGTH="${1:-}"
        ;;
      --no-special) SPECIAL=no ;;
      --no-copy) COPY=no ;;
      --count=*) COUNT="${arg#*=}" ;;
      --count)
        shift
        COUNT="${1:-}"
        ;;
      *)
        rec_ui_err "rec password: unknown arg '$arg'"
        return 2
        ;;
    esac
    shift
  done
  case "$LENGTH" in
    *[!0-9]* | '')
      rec_ui_err "--length must be a number"
      return 2
      ;;
  esac
  case "$COUNT" in
    *[!0-9]* | '')
      rec_ui_err "--count must be a number"
      return 2
      ;;
  esac
  if [ "$LENGTH" -lt 8 ] || [ "$LENGTH" -gt 256 ]; then
    rec_ui_err "--length must be between 8 and 256"
    return 2
  fi
  if [ "$COUNT" -lt 1 ]; then
    rec_ui_err "--count must be at least 1"
    return 2
  fi

  local charset='A-Za-z0-9'
  [ "$SPECIAL" = yes ] && charset='A-Za-z0-9!@#$%^&*\-_=+?'

  local i pw last=""
  i=0
  while [ "$i" -lt "$COUNT" ]; do
    pw="$(__rec_password_generate_one "$LENGTH" "$charset")" || return 1
    printf '%s\n' "$pw"
    last="$pw"
    i=$((i + 1))
  done

  if [ "$COPY" = yes ] && [ -n "$last" ]; then
    local clip
    if clip="$(__rec_password_clipboard_cmd)"; then
      # shellcheck disable=SC2086 # we want word-splitting on $clip
      if printf '%s' "$last" | $clip 2>/dev/null; then
        rec_ui_ok "copied to clipboard"
      else
        rec_ui_warn "clipboard tool failed"
      fi
    else
      rec_ui_warn "no clipboard tool found; printed only"
    fi
  fi
}
