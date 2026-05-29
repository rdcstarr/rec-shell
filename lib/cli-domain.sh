# shellcheck shell=bash
# shellcheck disable=SC2034 # internal globals are read across functions in this file
#
# lib/cli-domain.sh — the `rec domain` command group. Lazy-loaded by lib/cli.sh
# on the first `rec domain ...`. Two sub-commands:
#
#   rec domain check <domain>      Compact AVAILABLE / REGISTERED verdict.
#   rec domain scan <tld> --len N  Enumerate every N-char name on a TLD and
#                                  stream the available ones (with resume).
#
# Reuses helpers from lib/cli-whois.sh:
#   __rec_whois_text_says_available   detect "no match" / "AVAILABLE" phrasing
# The dispatcher in lib/cli.sh sources cli-whois.sh before us so they exist.

__rec_domain_dispatch() {
  _rd_cmd="${1:-}"
  if [ -z "$_rd_cmd" ]; then
    __rec_domain_help >&2
    return 2
  fi
  shift
  case "$_rd_cmd" in
    help | --help | -h)
      __rec_domain_help
      ;;
    check)
      if [ $# -eq 0 ]; then
        rec_ui_err 'rec domain check: <domain> is required'
        return 2
      fi
      __rec_domain_check "$1"
      ;;
    scan)
      if [ $# -eq 0 ]; then
        rec_ui_err 'rec domain scan: <tld> is required'
        __rec_domain_help >&2
        return 2
      fi
      __rec_domain_scan "$@"
      ;;
    *)
      rec_ui_err "rec domain: unknown command \"$_rd_cmd\""
      printf '\n' >&2
      __rec_domain_help >&2
      return 2
      ;;
  esac
}

__rec_domain_help() {
  cat <<'EOF'
rec domain — domain availability check and bulk scanner

Usage:
  rec domain check <domain>
  rec domain scan  <tld> --len N [flags]

Commands:
  check <domain>        AVAILABLE / REGISTERED verdict for one domain.
                        Exits 0=available, 1=registered, 2=unknown/error.

  scan <tld> --len N    Try every N-character name on <tld> and stream the
                        available ones. State is saved under
                        ~/.cache/rec-shell/domain/scans/ so an interrupted
                        scan can be resumed.

Scan flags:
  --len N            Required. Length of the name (without the TLD).
  --alphabet <set>   Characters to use (default: a-z). Ranges like a-z0-9
                     or A-Z are expanded; literal chars are kept as-is.
  --jobs N           Parallel workers (default: 8). Acts as a ceiling.
  --resume           Skip names already in the state file (default if
                     a state file exists). Refuses to resume across
                     mismatched alphabet/length runs.
  --reset            Delete the state file and start fresh.
  --rdap             Use only RDAP (skip whois fallback). Faster and more
                     stable for new gTLDs (.dev, .app, .page, …).
  --out <file>       Append each AVAILABLE name to <file> (one per line).
  --dry-run          Print the candidate list without doing lookups.

Examples:
  rec domain check example.com
  rec domain scan ro --len 2
  rec domain scan ro --len 3 --alphabet a-z0-9 --jobs 12
  rec domain scan dev --len 3 --rdap --out free.dev.txt
EOF
}

# --- single-domain check -------------------------------------------------

__rec_domain_check() {
  _rdc_in="$1"
  _rdc_domain="$(__rec_domain_normalize "$_rdc_in")"
  if [ -z "$_rdc_domain" ]; then
    rec_ui_err "rec domain check: invalid domain \"$_rdc_in\""
    return 2
  fi
  if ! rec_have curl && ! rec_have whois; then
    rec_ui_err 'need curl or whois to check domain availability'
    return 2
  fi

  unset _RD_DELAY_FILE
  _RD_RDAP_ONLY=no
  _RD_HTTP_TIMEOUT=10
  _RD_WHOIS_TIMEOUT=10

  # Interactive + TTY: animate a spinner while the lookup runs in the
  # background, then print the rendered verdict once. Non-interactive
  # (pipes, scripts, tests): render synchronously, no animation.
  rec_ui_interactive_load 2>/dev/null
  if command -v __rec_ui_interactive >/dev/null 2>&1 \
    && command -v __rec_ui_spin_frame >/dev/null 2>&1 \
    && __rec_ui_interactive; then
    _rdc_tmp="$(mktemp 2>/dev/null || mktemp -t rec-domain-check.XXXXXX)"
    # Interactive bash/zsh have monitor mode (job control) on by default,
    # which would bracket our spinner with "[N] pid" (job start) and
    # "[N] + done …" (job end) lines. Suppress the end line by turning
    # monitor mode off, and the start line by redirecting the backgrounding
    # group's stderr — the same technique rec_ui_spin uses. Restore the
    # user's monitor setting afterward. The verdict is captured to a temp
    # file (both streams: the colored status line uses rec_ui_err/warn on
    # stderr) and printed once, after the spinner is erased.
    case "$-" in *m*) _rdc_mon=1 ;; *) _rdc_mon=0 ;; esac
    set +m
    { __rec_domain_check_render "$_rdc_domain" >"$_rdc_tmp" 2>&1 & } 2>/dev/null
    _rdc_pid=$!
    trap '__rec_domain_check_spin_cleanup "$_rdc_pid" "$_rdc_mon" "$_rdc_tmp"' INT TERM
    {
      printf '\033[?25l'
      _rdc_i=0
      while kill -0 "$_rdc_pid" 2>/dev/null; do
        printf '\r'
        __rec_ui_emit 1 "$REC_UI_S_CYAN" "$(__rec_ui_spin_frame "$_rdc_i")"
        printf ' checking %s…' "$_rdc_domain"
        _rdc_i=$(((_rdc_i + 1) % 10))
        __rec_ui_sleep_frame
      done
      printf '\r\033[2K\033[?25h'
    } >&2
    wait "$_rdc_pid"
    _rdc_rc=$?
    trap - INT TERM
    [ "$_rdc_mon" = 1 ] && set -m
    cat "$_rdc_tmp"
    rm -f "$_rdc_tmp"
    return "$_rdc_rc"
  fi

  __rec_domain_check_render "$_rdc_domain"
}

# Spinner interrupt handler: kill the in-flight lookup, restore the cursor
# and the user's monitor-mode setting, drop the temp file, then re-raise
# SIGINT so the shell sees a clean Ctrl+C.
__rec_domain_check_spin_cleanup() {
  kill "$1" 2>/dev/null
  printf '\r\033[2K\033[?25h' >&2
  [ "$2" = 1 ] && set -m
  rm -f "$3" 2>/dev/null
  trap - INT TERM
  kill -INT $$ 2>/dev/null
}

# Render the verdict for one domain. Returns 0 when the status was
# determined (AVAILABLE or REGISTERED), 1 only when UNKNOWN/error — so an
# interactive prompt (e.g. ble.sh's "[ble: exit N]") flags a non-zero exit
# only on a genuine "couldn't tell", never on a normal "it's taken".
__rec_domain_check_render() {
  _rdcr_d="$1"
  _RD_WHOIS_OUT=""
  __rec_domain_check_one "$_rdcr_d"
  case "$_RD_STATUS" in
    AVAILABLE)
      rec_ui_ok "AVAILABLE   $_rdcr_d"
      rec_ui_note "looks unregistered (via $_RD_SOURCE) — you can register it"
      return 0
      ;;
    REGISTERED)
      rec_ui_err "REGISTERED  $_rdcr_d"
      __rec_domain_check_details "$_rdcr_d"
      rec_ui_note "source: $_RD_SOURCE"
      return 0
      ;;
    *)
      rec_ui_warn "UNKNOWN     $_rdcr_d"
      __rec_domain_check_unknown_hint "$_rdcr_d"
      return 1
      ;;
  esac
}

# Best-effort registrar + expiry for a REGISTERED domain. Reuses the whois
# text already fetched by check_one when it took the whois path; otherwise
# (RDAP said 200, no whois yet) runs a single whois for the detail lines.
# Parsing reuses the field helpers from cli-whois.sh.
__rec_domain_check_details() {
  command -v __rec_whois_field >/dev/null 2>&1 || return 0
  _rdcd_out="${_RD_WHOIS_OUT:-}"
  if [ -z "$_rdcd_out" ] && rec_have whois; then
    _rdcd_out="$(whois -- "$1" 2>/dev/null)" || _rdcd_out=""
  fi
  [ -z "$_rdcd_out" ] && return 0
  _rdcd_reg="$(__rec_whois_field "$_rdcd_out" 'Registrar')"
  [ -z "$_rdcd_reg" ] && _rdcd_reg="$(__rec_whois_field "$_rdcd_out" 'Sponsoring Registrar')"
  _rdcd_exp="$(__rec_whois_field "$_rdcd_out" 'Registry Expiry Date')"
  [ -z "$_rdcd_exp" ] && _rdcd_exp="$(__rec_whois_field "$_rdcd_out" 'Expiry Date')"
  [ -z "$_rdcd_exp" ] && _rdcd_exp="$(__rec_whois_field "$_rdcd_out" 'Expiration Date')"
  [ -z "$_rdcd_exp" ] && _rdcd_exp="$(__rec_whois_field "$_rdcd_out" 'Expires On')"
  [ -z "$_rdcd_exp" ] && _rdcd_exp="$(__rec_whois_field "$_rdcd_out" 'paid-till')"
  [ -n "$_rdcd_reg" ] && rec_ui_kv registrar "$_rdcd_reg"
  if [ -n "$_rdcd_exp" ] && command -v __rec_whois_kv_date >/dev/null 2>&1; then
    __rec_whois_kv_date expires "$_rdcd_exp" expires
  elif [ -n "$_rdcd_exp" ]; then
    rec_ui_kv expires "$_rdcd_exp"
  fi
}

# A short, human note explaining an UNKNOWN verdict.
__rec_domain_check_unknown_hint() {
  case "$_RD_SOURCE" in
    rdap-none)
      rec_ui_note "this TLD has no RDAP server and whois was unavailable/inconclusive"
      ;;
    whois-ratelimit)
      rec_ui_note "the registry rate-limited the whois query — try again shortly"
      ;;
    whois-empty)
      rec_ui_note "whois returned nothing — the registry may be unreachable"
      ;;
    whois-unclear)
      rec_ui_note "couldn't parse a clear answer — try: rec whois $1"
      ;;
    *)
      rec_ui_note "source: $_RD_SOURCE — try: rec whois $1"
      ;;
  esac
}

# Lowercase a string, strip a trailing dot, and reject anything that doesn't
# look like a domain (must contain a dot and only [a-z0-9.-]).
__rec_domain_normalize() {
  _rdn_in="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  _rdn_in="${_rdn_in%.}"
  case "$_rdn_in" in
    *.*) ;;
    *) return 0 ;;
  esac
  case "$_rdn_in" in
    *[!a-z0-9.-]*) return 0 ;;
  esac
  printf '%s' "$_rdn_in"
}

# --- scan: flag parsing + setup ------------------------------------------

__rec_domain_scan() {
  _RD_TLD=""
  _RD_LEN=""
  _RD_ALPHABET_SPEC="a-z"
  _RD_JOBS=8
  _RD_JOBS_EXPLICIT=no
  _RD_RDAP_ONLY=no
  _RD_SKIP_RDAP=no
  _RD_RESUME=auto
  _RD_RESET=no
  _RD_OUT=""
  _RD_DRY_RUN=no
  _RD_HTTP_TIMEOUT=10
  _RD_WHOIS_TIMEOUT=10

  while [ $# -gt 0 ]; do
    case "$1" in
      --len | -n)
        shift
        _RD_LEN="$1"
        ;;
      --alphabet)
        shift
        _RD_ALPHABET_SPEC="$1"
        ;;
      --jobs | -j)
        shift
        _RD_JOBS="$1"
        _RD_JOBS_EXPLICIT=yes
        ;;
      --resume) _RD_RESUME=yes ;;
      --reset) _RD_RESET=yes ;;
      --rdap) _RD_RDAP_ONLY=yes ;;
      --out)
        shift
        _RD_OUT="$1"
        ;;
      --dry-run) _RD_DRY_RUN=yes ;;
      --help | -h)
        __rec_domain_help
        return 0
        ;;
      -*)
        rec_ui_err "rec domain scan: unknown flag \"$1\""
        return 2
        ;;
      *)
        if [ -z "$_RD_TLD" ]; then
          _RD_TLD="$1"
        else
          rec_ui_err "rec domain scan: unexpected argument \"$1\""
          return 2
        fi
        ;;
    esac
    shift
  done

  if [ -z "$_RD_TLD" ]; then
    rec_ui_err 'rec domain scan: <tld> is required'
    return 2
  fi
  _RD_TLD="${_RD_TLD#.}"
  _RD_TLD="$(printf '%s' "$_RD_TLD" | tr '[:upper:]' '[:lower:]')"
  case "$_RD_TLD" in
    *[!a-z0-9.-]*)
      rec_ui_err "rec domain scan: invalid TLD \"$_RD_TLD\""
      return 2
      ;;
  esac
  if [ -z "$_RD_LEN" ] || ! __rec_domain_is_positive_int "$_RD_LEN"; then
    rec_ui_err 'rec domain scan: --len N (positive integer) is required'
    return 2
  fi
  if ! __rec_domain_is_positive_int "$_RD_JOBS"; then
    rec_ui_err "rec domain scan: --jobs must be a positive integer, got \"$_RD_JOBS\""
    return 2
  fi

  _RD_ALPHABET="$(__rec_domain_parse_alphabet "$_RD_ALPHABET_SPEC")"
  if [ -z "$_RD_ALPHABET" ]; then
    rec_ui_err "rec domain scan: empty alphabet from \"$_RD_ALPHABET_SPEC\""
    return 2
  fi

  if [ "$_RD_RDAP_ONLY" = no ] && ! rec_have whois; then
    rec_ui_warn "whois not found — falling back to --rdap mode"
    _RD_RDAP_ONLY=yes
  fi
  if ! rec_have curl; then
    rec_ui_err 'rec domain scan: curl is required'
    return 1
  fi

  _RD_TOTAL="$(__rec_domain_total "${#_RD_ALPHABET}" "$_RD_LEN")"

  if [ "$_RD_DRY_RUN" = yes ]; then
    __rec_domain_gen "$_RD_ALPHABET" "$_RD_LEN"
    return 0
  fi

  # Decide RDAP vs whois for this TLD before doing any work. rdap.org
  # returns a bare 404 (zero redirects) for TLDs with no RDAP server —
  # ccTLDs like .ro. Treating that as "available" reports every name as
  # free (the false-positive bug). One probe up front lets us route the
  # whole scan correctly instead of paying a useless RDAP round-trip per
  # candidate.
  _RD_SKIP_RDAP=no
  if ! __rec_domain_tld_has_rdap "$_RD_TLD"; then
    if [ "$_RD_RDAP_ONLY" = yes ]; then
      rec_ui_err "rec domain scan: .$_RD_TLD has no RDAP server — --rdap would report every name as UNKNOWN."
      rec_ui_step "drop --rdap to use whois (slower; the registry may rate-limit)"
      return 2
    fi
    if ! rec_have whois; then
      rec_ui_err "rec domain scan: .$_RD_TLD has no RDAP server and whois is not installed."
      return 1
    fi
    _RD_SKIP_RDAP=yes
    rec_ui_warn ".$_RD_TLD has no RDAP server — using whois only (slower; the registry may rate-limit aggressively)."
    # ccTLD whois servers (e.g. rotld) ban fast under load; keep
    # concurrency gentle unless the user explicitly asked for more.
    if [ "$_RD_JOBS_EXPLICIT" = no ] && [ "$_RD_JOBS" -gt 3 ]; then
      _RD_JOBS=3
      rec_ui_note "limited to --jobs 3 for a whois-only TLD (override with --jobs N)"
    fi
  fi

  __rec_domain_scan_run
}

# __rec_domain_tld_has_rdap TLD -> 0 if rdap.org can route this TLD to a
# real RDAP server. A supported TLD yields a redirect (≥1) to the registry
# RDAP endpoint even for a non-existent name; an unsupported TLD returns a
# bare 404 from rdap.org itself with zero redirects. On any network/curl
# failure we answer "no" so the caller falls back to whois.
__rec_domain_tld_has_rdap() {
  rec_have curl || return 1
  _rdth_r="$(curl -sSL -o /dev/null -w '%{num_redirects}' --max-time 10 \
    "https://rdap.org/domain/rec-shell-rdap-probe.$1" 2>/dev/null)"
  case "$_rdth_r" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "$_rdth_r" -ge 1 ]
}

# --- scan: main run -------------------------------------------------------

__rec_domain_scan_run() {
  # Interactive shells default to monitor mode (set -m), which prints
  # "[N] PID" and "[N]+ Done" lines for every backgrounded worker. Mute
  # them for the scan and restore the user's setting on the way out.
  _rd_monitor_was_on=no
  case "$-" in
    *m*) _rd_monitor_was_on=yes; set +m ;;
  esac

  _RD_DIR="$REC_CACHE_DIR/domain/scans"
  command mkdir -p "$_RD_DIR" 2>/dev/null || {
    rec_ui_err "cannot create $_RD_DIR"
    if [ "$_rd_monitor_was_on" = yes ]; then set -m; fi
    return 1
  }
  _rd_slug="$(__rec_domain_slug_alphabet "$_RD_ALPHABET_SPEC")"
  _RD_STATE_FILE="$_RD_DIR/${_RD_TLD}-${_RD_LEN}-${_rd_slug}.state"

  if [ "$_RD_RESET" = yes ] && [ -e "$_RD_STATE_FILE" ]; then
    rm -f "$_RD_STATE_FILE"
    rec_ui_info "removed previous state file"
  fi

  if [ -e "$_RD_STATE_FILE" ]; then
    if ! __rec_domain_state_matches "$_RD_STATE_FILE"; then
      rec_ui_err "state file at $_RD_STATE_FILE was created with different"
      rec_ui_err "settings (tld/length/alphabet). Re-run with --reset to start over."
      return 2
    fi
  else
    __rec_domain_write_header "$_RD_STATE_FILE"
  fi

  _rd_work="$(mktemp -d 2>/dev/null || mktemp -d -t rec-domain.XXXXXX)" || {
    rec_ui_err 'cannot create scratch directory'
    return 1
  }

  _rd_done_count="$(__rec_domain_count_done "$_RD_STATE_FILE")"
  _rd_remaining=$((_RD_TOTAL - _rd_done_count))
  [ "$_rd_remaining" -lt 0 ] && _rd_remaining=0

  rec_ui_heading "Scanning .$_RD_TLD (len $_RD_LEN, alphabet \"$_RD_ALPHABET_SPEC\") — $_RD_TOTAL candidates"
  if [ "$_rd_done_count" -gt 0 ]; then
    rec_ui_info "resuming from state: $_rd_done_count done, $_rd_remaining to go"
  fi
  rec_ui_note "state: $_RD_STATE_FILE"
  [ -n "$_RD_OUT" ] && rec_ui_note "also appending AVAILABLE names to: $_RD_OUT"
  rec_ui_note "Ctrl+C stops the scan; rerun the same command to resume."

  # Build the list of remaining candidates. BEGIN-getline avoids the
  # NR==FNR idiom, which silently passes nothing through when the done
  # file is empty.
  _rd_done_list="$_rd_work/done.list"
  awk -F'\t' '!/^#/ && NF >= 1 { print $1 }' "$_RD_STATE_FILE" >"$_rd_done_list" 2>/dev/null
  _rd_cands="$_rd_work/candidates"
  __rec_domain_gen "$_RD_ALPHABET" "$_RD_LEN" \
    | awk -v df="$_rd_done_list" '
        BEGIN { while ((getline line < df) > 0) d[line] = 1; close(df) }
        !($0 in d) { print }
      ' >"$_rd_cands"

  # Progress-bar glyphs (Unicode blocks, ASCII fallback) and the available
  # count carried over from a resumed run, so the bar's "found" total is
  # cumulative rather than just this session.
  if [ "${REC_UI_UTF:-no}" = yes ]; then
    _RD_BAR_FULL='█'; _RD_BAR_EMPTY='░'; _RD_BAR_L='▕'; _RD_BAR_R='▏'
  else
    _RD_BAR_FULL='#'; _RD_BAR_EMPTY='-'; _RD_BAR_L='['; _RD_BAR_R=']'
  fi
  _rd_avail_base="$(__rec_domain_count_status "$_RD_STATE_FILE" AVAILABLE)"

  # Ctrl+C handling. Two hard constraints pull against each other:
  #   1. SIGINT must actually stop the scan — so xargs runs in the foreground
  #      process group (`xargs | while`), where Ctrl+C reaches and kills it.
  #   2. We still want to print the interrupted-summary + resume hint.
  # But with `cmd | while`, the `while` runs in a subshell and zsh unwinds
  # scan_run on SIGINT before any post-pipeline code — so a "set a flag, check
  # it after" approach prints nothing under zsh. Solution: print the summary
  # FROM the trap itself. The trap fires in whichever context(s) caught the
  # signal (parent and/or the while-subshell); a mkdir mutex guarantees the
  # summary is emitted exactly once. `exit` is never used — that would close
  # the user's interactive shell, since `rec` is a function in it.
  _RD_INTERRUPTED=0
  _RD_SUMMARY_LOCK="$_rd_work/.summary.lock"
  trap '__rec_domain_on_interrupt' INT TERM

  # Run each candidate through a small POSIX-sh worker via xargs -P.
  # Concurrency lives entirely inside xargs — no shell fifos, no manual
  # worker pool, no record-time mutex. Workers print one tab-separated
  # line per candidate; that line goes back through a pipe to THIS shell,
  # which is the sole writer to the state file and to stdout. Small
  # writes from each worker are atomic on a pipe (≤ PIPE_BUF), so even
  # without locking nothing tears.
  # Mirrors __rec_domain_check_one, but as a standalone POSIX-sh snippet so
  # it can run under `xargs -P` without the surrounding shell context. A 404
  # from rdap.org only means "available" when it came from a real registry
  # RDAP server (≥1 redirect); a 0-redirect 404 means the TLD has no RDAP,
  # so we fall through to whois (and RD_SKIP_RDAP short-circuits straight to
  # whois for TLDs we already know lack RDAP).
  _rd_worker_script='
    d="$1"
    full="$d.$RD_TLD"
    if [ "$RD_SKIP_RDAP" != yes ]; then
      resp="$(curl -sSL -o /dev/null -w "%{http_code} %{num_redirects}" --max-time "$RD_TIMEOUT" "https://rdap.org/domain/$full" 2>/dev/null)"
      code="${resp%% *}"; redir="${resp##* }"
      case "$redir" in ""|*[!0-9]*) redir=0 ;; esac
      if [ "$code" = 200 ]; then printf "%s\tREGISTERED\trdap\n" "$d"; exit 0; fi
      if [ "$code" = 404 ] && [ "$redir" -ge 1 ]; then printf "%s\tAVAILABLE\trdap\n" "$d"; exit 0; fi
      if [ "$RD_RDAP_ONLY" = yes ]; then printf "%s\tUNKNOWN\trdap-%s\n" "$d" "${code:-error}"; exit 0; fi
    fi
    if ! command -v whois >/dev/null 2>&1; then printf "%s\tUNKNOWN\trdap-none\n" "$d"; exit 0; fi
    out="$(whois -- "$full" 2>/dev/null)" || out=""
    if [ -z "$out" ]; then printf "%s\tUNKNOWN\twhois-empty\n" "$d"; exit 0; fi
    if printf "%s\n" "$out" | grep -i -E -q "No match for|NOT FOUND|No Data Found|Domain not found|is free|No entries found|Status: *AVAILABLE|Status: *free"; then
      printf "%s\tAVAILABLE\twhois\n" "$d"
    elif printf "%s\n" "$out" | grep -i -E -q "rate.?limit|quota exceeded|try again later|exceeded the limit"; then
      printf "%s\tUNKNOWN\twhois-ratelimit\n" "$d"
    elif printf "%s\n" "$out" | grep -i -E -q "^[[:space:]]*(Domain Name|Registrar|Creation Date|Created):"; then
      printf "%s\tREGISTERED\twhois\n" "$d"
    else
      printf "%s\tUNKNOWN\twhois-unclear\n" "$d"
    fi
  '

  # Foreground xargs|while: Ctrl+C reaches xargs and its workers (they share
  # the foreground process group), so the scan genuinely STOPS — verified in
  # both bash and zsh. On bash the INT trap also fires and prints the
  # interrupted-summary; zsh hard-aborts the function on a SIGINT-killed
  # foreground pipeline, so it just returns to the prompt (no summary line).
  # Either way the per-result writes already landed, so re-running the exact
  # same command resumes (the upfront hint above tells the user how). We
  # never `exit` from the trap — `rec` is a function in the live shell.
  _rd_processed=0
  _rd_found=0
  RD_TLD="$_RD_TLD" RD_RDAP_ONLY="$_RD_RDAP_ONLY" RD_SKIP_RDAP="${_RD_SKIP_RDAP:-no}" RD_TIMEOUT="$_RD_HTTP_TIMEOUT" \
    xargs -P "$_RD_JOBS" -n 1 -I {} \
      sh -c "$_rd_worker_script" rec-domain-worker {} <"$_rd_cands" \
    | while IFS="$(printf '\t')" read -r _rd_c _rd_st _rd_src; do
        [ -z "$_rd_c" ] && continue
        printf '%s\t%s\t%s\n' "$_rd_c" "$_rd_st" "$_rd_src" >>"$_RD_STATE_FILE"
        if [ "$_rd_st" = AVAILABLE ]; then
          # Wipe the bottom progress bar so the result prints on a clean
          # line, then let the next bar redraw float below it (scrolling-log
          # over a pinned bar). Only when both streams are the same TTY.
          if [ -t 1 ] && [ -t 2 ]; then printf '\r\033[2K' >&2; fi
          __rec_domain_emit_available "$_rd_c.$_RD_TLD"
          [ -n "$_RD_OUT" ] && printf '%s\n' "$_rd_c.$_RD_TLD" >>"$_RD_OUT"
          _rd_found=$((_rd_found + 1))
        fi
        _rd_processed=$((_rd_processed + 1))
        __rec_domain_bar "$((_rd_done_count + _rd_processed))" "$_RD_TOTAL" \
          "$((_rd_avail_base + _rd_found))"
      done

  trap - INT TERM

  # On a clean finish, print the done-summary (the interrupt trap already
  # printed its own under the lock). Guard with the same lock so we never
  # double-print if both paths race.
  if [ "$_RD_INTERRUPTED" = 1 ]; then
    _rd_rc=130
  elif command mkdir "$_RD_SUMMARY_LOCK" 2>/dev/null; then
    __rec_domain_summary "done"
    _rd_rc=0
  else
    _rd_rc=0
  fi

  rm -rf "$_rd_work"
  if [ "$_rd_monitor_was_on" = yes ]; then set -m; fi
  return "$_rd_rc"
}

# SIGINT/SIGTERM handler for an in-progress scan. Records the interruption
# and prints the summary + resume hint exactly once (mkdir mutex — the trap
# may fire in both the parent shell and the `while` subshell). Never exits:
# `rec` is a function in the user's live shell, so an exit would close it.
__rec_domain_on_interrupt() {
  _RD_INTERRUPTED=1
  if command mkdir "$_RD_SUMMARY_LOCK" 2>/dev/null; then
    __rec_domain_summary "interrupted"
  fi
}

# Render the in-place progress bar to stderr (TTY only): a pinned bottom
# line like "▕████░░░░░░▏ 42%  19629/46656  ✓312". Carriage-return overwrites
# the line each call; AVAILABLE results scroll above it (they wipe the line
# first). No-op when stderr isn't a terminal, so pipes/tests stay clean.
# Args: processed total found.
__rec_domain_bar() {
  [ -t 2 ] || return 0
  _rdb_p="$1"; _rdb_t="$2"; _rdb_f="$3"
  _rdb_pct=0
  [ "$_rdb_t" -gt 0 ] && _rdb_pct=$((_rdb_p * 100 / _rdb_t))
  [ "$_rdb_pct" -gt 100 ] && _rdb_pct=100
  _rdb_w=24
  _rdb_fill=$((_rdb_pct * _rdb_w / 100))
  _rdb_full=""; _rdb_empty=""; _rdb_i=0
  while [ "$_rdb_i" -lt "$_rdb_fill" ]; do _rdb_full="$_rdb_full$_RD_BAR_FULL"; _rdb_i=$((_rdb_i + 1)); done
  while [ "$_rdb_i" -lt "$_rdb_w" ]; do _rdb_empty="$_rdb_empty$_RD_BAR_EMPTY"; _rdb_i=$((_rdb_i + 1)); done
  {
    printf '\r\033[2K%s' "$_RD_BAR_L"
    __rec_ui_emit 2 "$REC_UI_S_CYAN" "$_rdb_full"
    __rec_ui_emit 2 "$REC_UI_S_DIM" "$_rdb_empty"
    printf '%s ' "$_RD_BAR_R"
    __rec_ui_emit 2 "$REC_UI_S_BOLD" "$(printf '%3d%%' "$_rdb_pct")"
    printf '  %d/%d' "$_rdb_p" "$_rdb_t"
    if [ "$_rdb_f" -gt 0 ]; then
      printf '  '
      __rec_ui_emit 2 "$REC_UI_S_GREEN" "$REC_UI_G_OK$_rdb_f"
    fi
  } >&2
}

# Print final summary line plus a resume hint.
__rec_domain_summary() {
  _rds_kind="$1"
  _rds_done="$(__rec_domain_count_done "$_RD_STATE_FILE")"
  _rds_avail="$(__rec_domain_count_status "$_RD_STATE_FILE" AVAILABLE)"
  _rds_reg="$(__rec_domain_count_status "$_RD_STATE_FILE" REGISTERED)"
  _rds_unk="$(__rec_domain_count_status "$_RD_STATE_FILE" UNKNOWN)"
  # Wipe any leftover progress bar before the summary.
  [ -t 2 ] && printf '\r\033[2K' >&2
  printf '\n'
  if [ "$_rds_kind" = "interrupted" ]; then
    rec_ui_warn "Interrupted. $_rds_done/$_RD_TOTAL processed, $_rds_avail available so far."
    rec_ui_step "resume: rec domain scan $_RD_TLD --len $_RD_LEN --alphabet \"$_RD_ALPHABET_SPEC\""
  else
    rec_ui_ok "Done. $_rds_done/$_RD_TOTAL processed — available: $_rds_avail, registered: $_rds_reg, unknown: $_rds_unk."
  fi
  rec_ui_note "state: $_RD_STATE_FILE"
  [ -n "$_RD_OUT" ] && rec_ui_note "available list: $_RD_OUT"
}

# Single-line, single-write emission. Each scan_run reads xargs output
# line-by-line in the main shell and prints AVAILABLE entries from there,
# so there are no longer concurrent stdout writers; this helper just
# centralises the color/glyph choice.
__rec_domain_emit_available() {
  if [ "${REC_UI_C1:-0}" = 1 ]; then
    printf '\033[%sm%s\033[0m %s\n' "$REC_UI_S_GREEN" "$REC_UI_G_OK" "$1"
  else
    printf '%s %s\n' "$REC_UI_G_OK" "$1"
  fi
}

# --- single-domain classifier (used by `rec domain check`) ---------------
#
# Sets globals _RD_STATUS (AVAILABLE | REGISTERED | UNKNOWN) and _RD_SOURCE
# (rdap | whois | rdap-<code> | whois-empty | whois-ratelimit | whois-unclear).
# The bulk-scan path has its own inlined POSIX-sh worker (see scan_run)
# so it can run via `xargs -P` without dragging the whole shell context;
# this function is the readable, single-shot version used by `check`.
__rec_domain_check_one() {
  _rdco_d="$1"
  _RD_STATUS=UNKNOWN
  _RD_SOURCE=none

  _rdco_code=""
  _rdco_redir=0
  if rec_have curl; then
    # -L: rdap.org is a bootstrap aggregator that 302-redirects to the
    # actual RDAP server. We capture BOTH the final HTTP code and the
    # number of redirects, because a bare 404 from rdap.org itself
    # (0 redirects) means "this TLD has no RDAP server at all" — NOT that
    # the domain is free. ccTLDs like .ro have no RDAP, so every name
    # returns 404/0-redirects; trusting that as AVAILABLE was a
    # false-positive bug. Only a 404 that came FROM a real registry RDAP
    # server (≥1 redirect) means genuinely unregistered.
    _rdco_resp="$(curl -sSL -o /dev/null -w '%{http_code} %{num_redirects}' \
      --max-time "$_RD_HTTP_TIMEOUT" \
      "https://rdap.org/domain/$_rdco_d" 2>/dev/null)"
    _rdco_code="${_rdco_resp%% *}"
    _rdco_redir="${_rdco_resp##* }"
    case "$_rdco_redir" in '' | *[!0-9]*) _rdco_redir=0 ;; esac
  fi
  case "$_rdco_code" in
    200)
      _RD_STATUS=REGISTERED
      _RD_SOURCE=rdap
      return 0
      ;;
    404)
      if [ "$_rdco_redir" -ge 1 ]; then
        _RD_STATUS=AVAILABLE
        _RD_SOURCE=rdap
        return 0
      fi
      # 404 with no redirect -> TLD has no RDAP; fall through to whois.
      ;;
    *) ;;
  esac

  if [ "$_RD_RDAP_ONLY" = yes ] || ! rec_have whois; then
    _RD_STATUS=UNKNOWN
    if [ "$_rdco_code" = 404 ] && [ "$_rdco_redir" -lt 1 ]; then
      _RD_SOURCE="rdap-none"
    else
      _RD_SOURCE="rdap-${_rdco_code:-error}"
    fi
    return 0
  fi
  _rdco_out="$(whois -- "$_rdco_d" 2>/dev/null)" || _rdco_out=""
  _RD_WHOIS_OUT="$_rdco_out" # stashed so check_details can reuse it
  if [ -z "$_rdco_out" ]; then
    _RD_STATUS=UNKNOWN
    _RD_SOURCE=whois-empty
    return 0
  fi
  if printf '%s\n' "$_rdco_out" | __rec_whois_text_says_available; then
    _RD_STATUS=AVAILABLE
    _RD_SOURCE=whois
    return 0
  fi
  if printf '%s\n' "$_rdco_out" \
    | grep -i -E -q 'rate.?limit|quota exceeded|try again later|exceeded the limit'; then
    _RD_STATUS=UNKNOWN
    _RD_SOURCE=whois-ratelimit
    return 0
  fi
  if printf '%s\n' "$_rdco_out" \
    | grep -i -E -q '^[[:space:]]*(Domain Name|Registrar|Creation Date|Created):'; then
    _RD_STATUS=REGISTERED
    _RD_SOURCE=whois
    return 0
  fi
  _RD_STATUS=UNKNOWN
  _RD_SOURCE=whois-unclear
}

# --- alphabet generator ---------------------------------------------------

# Expand "a-z0-9" / "A-Z" / "abc" into a flat character string.
__rec_domain_parse_alphabet() {
  _rdpa_spec="$1"
  _rdpa_out=""
  while [ -n "$_rdpa_spec" ]; do
    _rdpa_h="${_rdpa_spec:0:1}"
    _rdpa_rest="${_rdpa_spec:1}"
    if [ "${_rdpa_rest:0:1}" = '-' ] && [ -n "${_rdpa_rest:1}" ]; then
      _rdpa_hi="${_rdpa_rest:1:1}"
      _rdpa_out="$_rdpa_out$(__rec_domain_char_range "$_rdpa_h" "$_rdpa_hi")"
      _rdpa_spec="${_rdpa_rest:2}"
    else
      _rdpa_out="$_rdpa_out$_rdpa_h"
      _rdpa_spec="$_rdpa_rest"
    fi
  done
  # De-duplicate while preserving order.
  printf '%s' "$_rdpa_out" | awk 'BEGIN { ORS="" }
    { n = length($0); for (i = 1; i <= n; i++) { c = substr($0, i, 1); if (!(c in seen)) { seen[c] = 1; printf "%s", c } } }'
}

# Emit every char from $1 to $2 inclusive (ASCII range).
__rec_domain_char_range() {
  _rdcr_lo_code="$(LC_CTYPE=C printf '%d' "'$1")"
  _rdcr_hi_code="$(LC_CTYPE=C printf '%d' "'$2")"
  [ "$_rdcr_lo_code" -le "$_rdcr_hi_code" ] || return 0
  awk -v lo="$_rdcr_lo_code" -v hi="$_rdcr_hi_code" \
    'BEGIN { for (i = lo; i <= hi; i++) printf "%c", i }'
}

# __rec_domain_gen ALPHABET LEN -> emit every length-LEN cartesian product of
# the chars in ALPHABET, lex order, one per line. Implemented as a base-N
# counter — recursion via shell functions would clobber globals (no `local`
# in our prefix style) and stack-overflow on bigger scans.
__rec_domain_gen() {
  _rdg_alpha="$1"
  _rdg_len="$2"
  _rdg_n=${#_rdg_alpha}
  [ "$_rdg_n" -gt 0 ] || return 0
  [ "$_rdg_len" -gt 0 ] || return 0
  _rdg_total="$(__rec_domain_total "$_rdg_n" "$_rdg_len")"
  _rdg_idx=0
  while [ "$_rdg_idx" -lt "$_rdg_total" ]; do
    _rdg_v="$_rdg_idx"
    _rdg_cur=""
    _rdg_i=0
    while [ "$_rdg_i" -lt "$_rdg_len" ]; do
      _rdg_d=$((_rdg_v % _rdg_n))
      _rdg_v=$((_rdg_v / _rdg_n))
      _rdg_cur="${_rdg_alpha:$_rdg_d:1}$_rdg_cur"
      _rdg_i=$((_rdg_i + 1))
    done
    printf '%s\n' "$_rdg_cur"
    _rdg_idx=$((_rdg_idx + 1))
  done
}

__rec_domain_total() {
  awk -v a="$1" -v n="$2" 'BEGIN {
    t = 1; for (i = 0; i < n; i++) t *= a; printf "%d", t
  }'
}

# --- state file helpers ---------------------------------------------------

__rec_domain_slug_alphabet() {
  # Make the alphabet spec safe for filenames: lowercase, replace runs of
  # non-[a-z0-9-] with a single "_".
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9-]+/_/g; s/^_//; s/_$//'
}

__rec_domain_write_header() {
  {
    printf '# rec-domain-scan v1\n'
    printf '# tld: %s\n' "$_RD_TLD"
    printf '# length: %s\n' "$_RD_LEN"
    printf '# alphabet: %s\n' "$_RD_ALPHABET_SPEC"
    printf '# started: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '# total: %s\n' "$_RD_TOTAL"
  } >"$1"
}

__rec_domain_state_matches() {
  _rdsm_file="$1"
  _rdsm_tld="$(awk '/^# tld:/ { print $3; exit }' "$_rdsm_file" 2>/dev/null)"
  _rdsm_len="$(awk '/^# length:/ { print $3; exit }' "$_rdsm_file" 2>/dev/null)"
  _rdsm_alpha="$(awk '/^# alphabet:/ { print $3; exit }' "$_rdsm_file" 2>/dev/null)"
  [ "$_rdsm_tld" = "$_RD_TLD" ] \
    && [ "$_rdsm_len" = "$_RD_LEN" ] \
    && [ "$_rdsm_alpha" = "$_RD_ALPHABET_SPEC" ]
}

__rec_domain_count_done() {
  [ -r "$1" ] || {
    printf '0'
    return 0
  }
  awk '!/^#/ && NF >= 1' "$1" 2>/dev/null | wc -l | tr -d ' '
}

__rec_domain_count_status() {
  [ -r "$1" ] || {
    printf '0'
    return 0
  }
  awk -F'\t' -v s="$2" '!/^#/ && $2 == s' "$1" 2>/dev/null | wc -l | tr -d ' '
}

# --- misc -----------------------------------------------------------------

__rec_domain_is_positive_int() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
    0*) return 1 ;;
  esac
  return 0
}
