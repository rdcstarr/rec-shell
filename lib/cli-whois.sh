# shellcheck shell=bash
#
# lib/cli-whois.sh — the `rec whois` command group. Lazy-loaded by lib/cli.sh
# on the first `rec whois ...`. Auto-detects whether the target is a domain or
# an IP and shows the relevant info in a uniform layout.
#
#   rec whois <target>          auto-detect (domain or IPv4/IPv6)
#   rec whois domain <domain>   force domain mode
#   rec whois ip <ip>           force IP mode (whois + geo + reverse DNS)
#
# For your own public IP, use `rec ip public` (or just `rec ip`).

__rec_whois_dispatch() {
  _rw_cmd="${1:-}"
  if [ -z "$_rw_cmd" ]; then
    if rec_ui_interactive_load && __rec_ui_interactive; then
      _rw_cmd="$(rec_ui_input 'Target (domain or IP)')"
      [ -z "$_rw_cmd" ] && return 0
    else
      rec_ui_err "rec whois: <target> is required (domain or IP)"
      printf '\n' >&2
      __rec_whois_help >&2
      return 2
    fi
  fi
  case "$_rw_cmd" in
    help | --help | -h)
      __rec_whois_help
      ;;
    domain)
      shift
      if [ $# -eq 0 ]; then
        rec_ui_err "rec whois domain: <domain> is required"
        return 2
      fi
      __rec_whois_domain "$1"
      ;;
    ip)
      shift
      if [ $# -eq 0 ]; then
        rec_ui_err "rec whois ip: <ip> is required"
        return 2
      fi
      __rec_whois_ip "$1"
      ;;
    *)
      if __rec_whois_is_ip "$_rw_cmd"; then
        __rec_whois_ip "$_rw_cmd"
      else
        __rec_whois_domain "$_rw_cmd"
      fi
      ;;
  esac
}

__rec_whois_help() {
  cat <<'EOF'
rec whois — whois lookup for domains and IPs

Usage: rec whois <target>
       rec whois domain <domain>
       rec whois ip <ip>

Auto-detects whether <target> is a domain or an IPv4/IPv6 address and shows:
  • domain: registrar, dates, status, name servers, availability
  • ip:     whois (range/org/ASN/abuse) + geolocation + reverse DNS (PTR)

For your own public IP, use:
  rec ip          (or: rec ip public)

Examples:
  rec whois example.com
  rec whois 8.8.8.8
  rec whois 2606:4700:4700::1111
  rec whois domain example.com
  rec whois ip 1.1.1.1
EOF
}

# __rec_whois_is_ip TARGET -> 0 if TARGET looks like an IPv4 or IPv6 address.
# IPv6 detection is intentionally permissive: anything with two or more ':'.
# IPv4 must be four dot-separated runs of digits.
__rec_whois_is_ip() {
  case "$1" in
    *:*:*) return 0 ;;
  esac
  case "$1" in
    *[!0-9.]*) return 1 ;;
  esac
  # exactly three dots, no other chars
  _rwi_dots="${1//[^.]/}"
  [ "${#_rwi_dots}" -eq 3 ] || return 1
  return 0
}

# Trim leading/trailing whitespace from $1, echo to stdout.
__rec_whois_trim() {
  _rwt="$1"
  _rwt="${_rwt#"${_rwt%%[![:space:]]*}"}"
  _rwt="${_rwt%"${_rwt##*[![:space:]]}"}"
  printf '%s' "$_rwt"
}

# Extract the FIRST value for a given whois field. Matches case-insensitively
# against the start of each line, splits on the first ':' and trims.
# Usage: __rec_whois_field "<whois output>" "Registrar"
__rec_whois_field() {
  printf '%s\n' "$1" \
    | grep -i -m1 -E "^[[:space:]]*$2[[:space:]]*:" \
    | head -n1 \
    | sed -E 's/^[^:]*:[[:space:]]*//' \
    | tr -d '\r'
}

# Read whois output text from stdin; return 0 if the response uses any of the
# common "domain is not registered" phrasings. Shared with cli-domain.sh.
__rec_whois_text_says_available() {
  grep -i -E -q 'No match for|NOT FOUND|No Data Found|Domain not found|is free|No entries found|Status: *AVAILABLE|Status: *free'
}

# Extract ALL values for a field, one per line.
__rec_whois_field_all() {
  printf '%s\n' "$1" \
    | grep -i -E "^[[:space:]]*$2[[:space:]]*:" \
    | sed -E 's/^[^:]*:[[:space:]]*//' \
    | tr -d '\r' \
    | awk 'NF && !seen[tolower($0)]++'
}

# Continuation line under a rec_ui_kv row: aligns the value under the previous
# value (key column is "%-10s " in rec_ui_kv, so 11 chars of leading padding).
# Used when a single field has multiple values (status, name servers, PTR…),
# which would otherwise render a bare ":" as the continuation key.
__rec_whois_kv_cont() {
  printf '%11s%s\n' '' "$1"
}

# __rec_whois_date_epoch DATESTR -> seconds since the epoch, or non-zero exit.
# Handles both GNU date (Linux) and BSD date (mac); tries the common ISO/RFC
# layouts in turn. Returns silently on failure so the caller can skip the
# humanization without aborting the row.
__rec_whois_date_epoch() {
  _rwde_in="$1"
  [ -z "$_rwde_in" ] && return 1
  # 1) GNU date — accepts a wide variety of free-form strings.
  _rwde_out="$(date -d "$_rwde_in" +%s 2>/dev/null)"
  case "$_rwde_out" in
    '' | *[!0-9-]*) _rwde_out="" ;;
  esac
  if [ -n "$_rwde_out" ]; then
    printf '%s' "$_rwde_out"
    return 0
  fi
  # 2) BSD date — strict; normalize the input and try a few known formats.
  _rwde_clean="$(printf '%s' "$_rwde_in" \
    | sed -E 's/\.[0-9]+(Z|[+-].*)?$//; s/Z$//; s/[+-][0-9]{2}:?[0-9]{2}$//')"
  for _rwde_fmt in '%Y-%m-%dT%H:%M:%S' '%Y-%m-%d %H:%M:%S' '%Y-%m-%d' '%d-%b-%Y' '%Y/%m/%d'; do
    _rwde_out="$(date -j -f "$_rwde_fmt" "$_rwde_clean" +%s 2>/dev/null)"
    case "$_rwde_out" in
      '' | *[!0-9-]*) continue ;;
    esac
    printf '%s' "$_rwde_out"
    return 0
  done
  return 1
}

# __rec_whois_humanize_date DATESTR [kind] -> a parenthesized phrase like
# "1 year, 15 days ago", "in 10 months", or "today". KIND ∈ {created, updated,
# expires} adjusts wording: for `expires` in the past, prefixes "expired ".
# Emits nothing on parse failure.
__rec_whois_humanize_date() {
  _rwhd_in="$1"
  _rwhd_kind="${2:-}"
  _rwhd_epoch="$(__rec_whois_date_epoch "$_rwhd_in")" || return 0
  _rwhd_now="$(date +%s)"
  _rwhd_diff=$((_rwhd_epoch - _rwhd_now))
  if [ "$_rwhd_diff" -lt 0 ]; then
    _rwhd_past=yes
    _rwhd_diff=$((-_rwhd_diff))
  else
    _rwhd_past=no
  fi
  _rwhd_days=$((_rwhd_diff / 86400))
  if [ "$_rwhd_days" -eq 0 ]; then
    printf 'today'
    return 0
  fi
  # Approximate calendar units: 365d/yr, 30d/mo. Good enough for "(X ago)" UX.
  _rwhd_y=$((_rwhd_days / 365))
  _rwhd_rest=$((_rwhd_days - _rwhd_y * 365))
  _rwhd_m=$((_rwhd_rest / 30))
  _rwhd_d=$((_rwhd_rest - _rwhd_m * 30))

  _rwhd_txt=""
  if [ "$_rwhd_y" -gt 0 ]; then
    _rwhd_txt="$(__rec_whois_unit "$_rwhd_y" year)"
    [ "$_rwhd_m" -gt 0 ] && _rwhd_txt="$_rwhd_txt, $(__rec_whois_unit "$_rwhd_m" month)"
  elif [ "$_rwhd_m" -gt 0 ]; then
    _rwhd_txt="$(__rec_whois_unit "$_rwhd_m" month)"
    [ "$_rwhd_d" -gt 0 ] && _rwhd_txt="$_rwhd_txt, $(__rec_whois_unit "$_rwhd_d" day)"
  else
    _rwhd_txt="$(__rec_whois_unit "$_rwhd_d" day)"
  fi

  if [ "$_rwhd_past" = yes ]; then
    if [ "$_rwhd_kind" = expires ]; then
      printf 'expired %s ago' "$_rwhd_txt"
    else
      printf '%s ago' "$_rwhd_txt"
    fi
  else
    printf 'in %s' "$_rwhd_txt"
  fi
}

# __rec_whois_unit N WORD -> "1 year" or "3 years" — pluralizes on N≠1.
__rec_whois_unit() {
  if [ "$1" -eq 1 ]; then
    printf '%s %s' "$1" "$2"
  else
    printf '%s %ss' "$1" "$2"
  fi
}

# __rec_whois_kv_date KEY VALUE [kind] -> rec_ui_kv-style row plus a dim
# "(humanized duration)" suffix. KIND is forwarded to __rec_whois_humanize_date.
__rec_whois_kv_date() {
  _rwkd_k="$1"
  _rwkd_v="$2"
  _rwkd_kind="${3:-}"
  __rec_ui_emit 1 "$REC_UI_S_DIM" "$(printf '%-10s' "$_rwkd_k:")"
  printf ' %s' "$_rwkd_v"
  _rwkd_hum="$(__rec_whois_humanize_date "$_rwkd_v" "$_rwkd_kind")"
  if [ -n "$_rwkd_hum" ]; then
    printf ' '
    __rec_ui_emit 1 "$REC_UI_S_DIM" "($_rwkd_hum)"
  fi
  printf '\n'
}

# rec whois domain <domain>
# __rec_whois_rdap_domain DOMAIN -> query rdap.org for DOMAIN, parse the
# JSON, and emit it in the same UI shape as the whois path. Returns 0 on
# success (RDAP responded with valid JSON we could parse), 1 otherwise.
#
# Required for new gTLDs that dropped whois entirely (.dev, .app, .page,
# .new, …) — IANA's bootstrap shows their `whois:` field empty; whois
# clients with hardcoded `whois.nic.<tld>` mappings fail with NXDOMAIN.
__rec_whois_rdap_domain() {
  _rwr_domain="$1"
  rec_have python3 || rec_have python || return 1
  _rwr_py="$(rec_have python3 && echo python3 || echo python)"
  _rwr_json="$(curl -fsSL --max-time 10 "https://rdap.org/domain/$_rwr_domain" 2>/dev/null)"
  [ -z "$_rwr_json" ] && return 1
  # One-shot parse: emit `key<TAB>value` lines for the fields we care
  # about, then read them back. Returns rc=1 if the JSON isn't a domain
  # response (e.g. error envelope).
  _rwr_kv="$(printf '%s' "$_rwr_json" | "$_rwr_py" -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if d.get("objectClassName") != "domain":
    sys.exit(1)
def vcard_fn(entity):
    for item in (entity.get("vcardArray") or [None, []])[1]:
        if isinstance(item, list) and item and item[0] == "fn":
            return item[3] if len(item) > 3 else ""
    return ""
print("ldh\t" + (d.get("ldhName") or ""))
for ent in d.get("entities") or []:
    if "registrar" in (ent.get("roles") or []):
        print("registrar\t" + vcard_fn(ent))
        break
for ev in d.get("events") or []:
    act = ev.get("eventAction") or ""
    when = ev.get("eventDate") or ""
    if act == "registration": print("created\t" + when)
    elif act == "expiration": print("expires\t" + when)
    elif act in ("last changed", "last update of RDAP database"): print("updated\t" + when)
for s in d.get("status") or []:
    print("status\t" + s)
for ns in d.get("nameservers") or []:
    nm = ns.get("ldhName") or ""
    if nm: print("ns\t" + nm.lower())
sd = d.get("secureDNS") or {}
if "delegationSigned" in sd:
    print("dnssec\t" + ("signed" if sd.get("delegationSigned") else "unsigned"))
' 2>/dev/null)"
  [ -z "$_rwr_kv" ] && return 1

  rec_ui_heading "WHOIS: $_rwr_domain"
  rec_ui_kv target "$_rwr_domain"
  rec_ui_note "source:    RDAP (rdap.org)"

  _rwr_registrar="$(printf '%s\n' "$_rwr_kv" | awk -F'\t' '$1=="registrar"{print $2; exit}')"
  _rwr_created="$(printf '%s\n' "$_rwr_kv" | awk -F'\t' '$1=="created"{print $2; exit}')"
  _rwr_updated="$(printf '%s\n' "$_rwr_kv" | awk -F'\t' '$1=="updated"{print $2; exit}')"
  _rwr_expires="$(printf '%s\n' "$_rwr_kv" | awk -F'\t' '$1=="expires"{print $2; exit}')"
  _rwr_dnssec="$(printf '%s\n' "$_rwr_kv" | awk -F'\t' '$1=="dnssec"{print $2; exit}')"
  [ -n "$_rwr_registrar" ] && rec_ui_kv registrar "$_rwr_registrar"
  [ -n "$_rwr_created" ] && __rec_whois_kv_date created "$_rwr_created" created
  [ -n "$_rwr_updated" ] && __rec_whois_kv_date updated "$_rwr_updated" updated
  [ -n "$_rwr_expires" ] && __rec_whois_kv_date expires "$_rwr_expires" expires
  [ -n "$_rwr_dnssec" ] && rec_ui_kv dnssec "$_rwr_dnssec"

  _rwr_first=1
  printf '%s\n' "$_rwr_kv" | awk -F'\t' '$1=="status"{print $2}' | while IFS= read -r _rwr_s; do
    [ -z "$_rwr_s" ] && continue
    if [ "$_rwr_first" -eq 1 ]; then
      rec_ui_kv status "$_rwr_s"
      _rwr_first=0
    else
      __rec_whois_kv_cont "$_rwr_s"
    fi
  done

  _rwr_first=1
  printf '%s\n' "$_rwr_kv" | awk -F'\t' '$1=="ns"{print $2}' | while IFS= read -r _rwr_n; do
    [ -z "$_rwr_n" ] && continue
    if [ "$_rwr_first" -eq 1 ]; then
      rec_ui_kv ns "$_rwr_n"
      _rwr_first=0
    else
      __rec_whois_kv_cont "$_rwr_n"
    fi
  done
  unset _rwr_domain _rwr_py _rwr_json _rwr_kv _rwr_registrar _rwr_created _rwr_updated _rwr_expires _rwr_dnssec _rwr_first _rwr_s _rwr_n
  return 0
}

__rec_whois_domain() {
  _rwd_domain="$1"
  if ! rec_have whois; then
    rec_ui_err "'whois' is required for domain lookup"
    rec_ui_note "install with: brew install whois  /  sudo apt install whois  /  sudo dnf install whois"
    rec_ui_note "or re-run the installer: ./install.sh --tools=whois"
    return 1
  fi

  # Capture stderr separately so we can surface the real cause when the
  # lookup fails (DNS error reaching whois.nic.<tld>, connection refused
  # by the registry's whois server, network blocked, …) instead of the
  # misleading "no data" message.
  _rwd_err="$(mktemp 2>/dev/null || mktemp -t rec-whois.XXXXXX)"
  _rwd_out="$(whois -- "$_rwd_domain" 2>"$_rwd_err")" || _rwd_out=""
  if [ -z "$_rwd_out" ]; then
    # Whois failed or returned nothing. Try the RDAP fallback — newer
    # gTLDs like .dev / .app / .page are RDAP-only (IANA shows their
    # whois field as empty; the stale `whois.nic.<tld>` hostname some
    # whois packages hardcode doesn't exist). rdap.org is a public
    # bootstrap aggregator that redirects to the correct RDAP server.
    if rec_have curl && __rec_whois_rdap_domain "$_rwd_domain"; then
      rm -f "$_rwd_err"
      return 0
    fi
    if [ -s "$_rwd_err" ]; then
      rec_ui_err "whois lookup failed for '$_rwd_domain':"
      sed 's/^/  /' "$_rwd_err" >&2
    else
      rec_ui_err "whois returned no data for '$_rwd_domain'"
    fi
    rm -f "$_rwd_err"
    return 1
  fi
  rm -f "$_rwd_err"

  rec_ui_heading "WHOIS: $_rwd_domain"
  rec_ui_kv target "$_rwd_domain"

  # Availability detection — common phrasings across registries.
  if printf '%s\n' "$_rwd_out" | __rec_whois_text_says_available; then
    rec_ui_ok "status:    AVAILABLE (no registration record found)"
    return 0
  fi

  # Try multiple label variants per field (whois output varies by registry).
  _rwd_registrar="$(__rec_whois_field "$_rwd_out" 'Registrar')"
  [ -z "$_rwd_registrar" ] && _rwd_registrar="$(__rec_whois_field "$_rwd_out" 'Sponsoring Registrar')"

  _rwd_created="$(__rec_whois_field "$_rwd_out" 'Creation Date')"
  [ -z "$_rwd_created" ] && _rwd_created="$(__rec_whois_field "$_rwd_out" 'Created')"
  [ -z "$_rwd_created" ] && _rwd_created="$(__rec_whois_field "$_rwd_out" 'Registered on')"
  [ -z "$_rwd_created" ] && _rwd_created="$(__rec_whois_field "$_rwd_out" 'created')"

  _rwd_updated="$(__rec_whois_field "$_rwd_out" 'Updated Date')"
  [ -z "$_rwd_updated" ] && _rwd_updated="$(__rec_whois_field "$_rwd_out" 'Last Updated')"
  [ -z "$_rwd_updated" ] && _rwd_updated="$(__rec_whois_field "$_rwd_out" 'last-update')"
  [ -z "$_rwd_updated" ] && _rwd_updated="$(__rec_whois_field "$_rwd_out" 'changed')"

  _rwd_expiry="$(__rec_whois_field "$_rwd_out" 'Registry Expiry Date')"
  [ -z "$_rwd_expiry" ] && _rwd_expiry="$(__rec_whois_field "$_rwd_out" 'Expiry Date')"
  [ -z "$_rwd_expiry" ] && _rwd_expiry="$(__rec_whois_field "$_rwd_out" 'Expiration Date')"
  [ -z "$_rwd_expiry" ] && _rwd_expiry="$(__rec_whois_field "$_rwd_out" 'Expires On')"
  [ -z "$_rwd_expiry" ] && _rwd_expiry="$(__rec_whois_field "$_rwd_out" 'paid-till')"

  _rwd_status="$(__rec_whois_field_all "$_rwd_out" 'Domain Status')"
  [ -z "$_rwd_status" ] && _rwd_status="$(__rec_whois_field "$_rwd_out" 'Status')"

  _rwd_ns="$(__rec_whois_field_all "$_rwd_out" 'Name Server')"
  [ -z "$_rwd_ns" ] && _rwd_ns="$(__rec_whois_field_all "$_rwd_out" 'nserver')"

  _rwd_dnssec="$(__rec_whois_field "$_rwd_out" 'DNSSEC')"

  [ -n "$_rwd_registrar" ] && rec_ui_kv registrar "$_rwd_registrar"
  [ -n "$_rwd_created" ] && __rec_whois_kv_date created "$_rwd_created" created
  [ -n "$_rwd_updated" ] && __rec_whois_kv_date updated "$_rwd_updated" updated
  [ -n "$_rwd_expiry" ] && __rec_whois_kv_date expires "$_rwd_expiry" expires
  [ -n "$_rwd_dnssec" ] && rec_ui_kv dnssec "$_rwd_dnssec"

  if [ -n "$_rwd_status" ]; then
    _rwd_first=1
    printf '%s\n' "$_rwd_status" | while IFS= read -r _rwd_s; do
      [ -z "$_rwd_s" ] && continue
      if [ "$_rwd_first" -eq 1 ]; then
        rec_ui_kv status "$_rwd_s"
        _rwd_first=0
      else
        __rec_whois_kv_cont "$_rwd_s"
      fi
    done
  fi

  if [ -n "$_rwd_ns" ]; then
    _rwd_first=1
    printf '%s\n' "$_rwd_ns" | while IFS= read -r _rwd_n; do
      [ -z "$_rwd_n" ] && continue
      if [ "$_rwd_first" -eq 1 ]; then
        rec_ui_kv ns "$_rwd_n"
        _rwd_first=0
      else
        __rec_whois_kv_cont "$_rwd_n"
      fi
    done
  fi

  # If nothing parsed, hint at the raw command (some ccTLDs return free-form text).
  if [ -z "$_rwd_registrar$_rwd_created$_rwd_updated$_rwd_expiry$_rwd_status$_rwd_ns" ]; then
    rec_ui_note "no standard fields parsed — try: whois $_rwd_domain"
  fi
}

# rec whois ip <ip>
__rec_whois_ip() {
  _rwip_ip="$1"
  if ! rec_have whois; then
    rec_ui_err "'whois' is required for IP lookup"
    rec_ui_note "install with: brew install whois  /  sudo apt install whois  /  sudo dnf install whois"
    rec_ui_note "or re-run the installer: ./install.sh --tools=whois"
    return 1
  fi

  rec_ui_heading "WHOIS: $_rwip_ip"

  _rwip_out="$(whois -- "$_rwip_ip" 2>/dev/null)" || _rwip_out=""
  if [ -n "$_rwip_out" ]; then
    _rwip_range="$(__rec_whois_field "$_rwip_out" 'NetRange')"
    [ -z "$_rwip_range" ] && _rwip_range="$(__rec_whois_field "$_rwip_out" 'inetnum')"
    [ -z "$_rwip_range" ] && _rwip_range="$(__rec_whois_field "$_rwip_out" 'inet6num')"

    _rwip_cidr="$(__rec_whois_field "$_rwip_out" 'CIDR')"
    [ -z "$_rwip_cidr" ] && _rwip_cidr="$(__rec_whois_field "$_rwip_out" 'route')"
    [ -z "$_rwip_cidr" ] && _rwip_cidr="$(__rec_whois_field "$_rwip_out" 'route6')"

    _rwip_netname="$(__rec_whois_field "$_rwip_out" 'NetName')"
    [ -z "$_rwip_netname" ] && _rwip_netname="$(__rec_whois_field "$_rwip_out" 'netname')"

    _rwip_org="$(__rec_whois_field "$_rwip_out" 'OrgName')"
    [ -z "$_rwip_org" ] && _rwip_org="$(__rec_whois_field "$_rwip_out" 'org-name')"
    [ -z "$_rwip_org" ] && _rwip_org="$(__rec_whois_field "$_rwip_out" 'descr')"
    [ -z "$_rwip_org" ] && _rwip_org="$(__rec_whois_field "$_rwip_out" 'owner')"

    _rwip_country="$(__rec_whois_field "$_rwip_out" 'Country')"
    [ -z "$_rwip_country" ] && _rwip_country="$(__rec_whois_field "$_rwip_out" 'country')"

    _rwip_asn="$(__rec_whois_field "$_rwip_out" 'OriginAS')"
    [ -z "$_rwip_asn" ] && _rwip_asn="$(__rec_whois_field "$_rwip_out" 'origin')"

    _rwip_abuse="$(__rec_whois_field "$_rwip_out" 'OrgAbuseEmail')"
    [ -z "$_rwip_abuse" ] && _rwip_abuse="$(__rec_whois_field "$_rwip_out" 'abuse-mailbox')"
    [ -z "$_rwip_abuse" ] && _rwip_abuse="$(__rec_whois_field "$_rwip_out" 'abuse-c')"

    [ -n "$_rwip_range" ] && rec_ui_kv range "$_rwip_range"
    [ -n "$_rwip_cidr" ] && rec_ui_kv cidr "$_rwip_cidr"
    [ -n "$_rwip_netname" ] && rec_ui_kv netname "$_rwip_netname"
    [ -n "$_rwip_org" ] && rec_ui_kv org "$_rwip_org"
    [ -n "$_rwip_country" ] && rec_ui_kv country "$_rwip_country"
    [ -n "$_rwip_asn" ] && rec_ui_kv asn "$_rwip_asn"
    [ -n "$_rwip_abuse" ] && rec_ui_kv abuse "$_rwip_abuse"
  else
    rec_ui_note "whois returned no data"
  fi

  # --- Geolocation via ipinfo.io (no key needed for basic data).
  if rec_have curl; then
    printf '\n'
    rec_ui_heading "GEO: $_rwip_ip"
    _rwip_geo="$(curl -fsSL --max-time 5 "https://ipinfo.io/$_rwip_ip/json" 2>/dev/null)" || _rwip_geo=""
    if [ -n "$_rwip_geo" ]; then
      _rwip_v_hostname="$(__rec_whois_json_field "$_rwip_geo" hostname)"
      _rwip_v_city="$(__rec_whois_json_field "$_rwip_geo" city)"
      _rwip_v_region="$(__rec_whois_json_field "$_rwip_geo" region)"
      _rwip_v_country="$(__rec_whois_json_field "$_rwip_geo" country)"
      _rwip_v_org="$(__rec_whois_json_field "$_rwip_geo" org)"
      _rwip_v_loc="$(__rec_whois_json_field "$_rwip_geo" loc)"
      _rwip_v_tz="$(__rec_whois_json_field "$_rwip_geo" timezone)"
      _rwip_v_postal="$(__rec_whois_json_field "$_rwip_geo" postal)"
      [ -n "$_rwip_v_hostname" ] && rec_ui_kv hostname "$_rwip_v_hostname"
      [ -n "$_rwip_v_city" ] && rec_ui_kv city "$_rwip_v_city"
      [ -n "$_rwip_v_region" ] && rec_ui_kv region "$_rwip_v_region"
      [ -n "$_rwip_v_country" ] && rec_ui_kv country "$_rwip_v_country"
      [ -n "$_rwip_v_postal" ] && rec_ui_kv postal "$_rwip_v_postal"
      [ -n "$_rwip_v_loc" ] && rec_ui_kv location "$_rwip_v_loc"
      [ -n "$_rwip_v_org" ] && rec_ui_kv org "$_rwip_v_org"
      [ -n "$_rwip_v_tz" ] && rec_ui_kv timezone "$_rwip_v_tz"
      if [ -z "$_rwip_v_city$_rwip_v_country$_rwip_v_org" ]; then
        rec_ui_note "geo lookup returned no usable fields"
      fi
    else
      rec_ui_note "geo lookup failed (offline or rate-limited)"
    fi
  fi

  # --- Reverse DNS (PTR).
  if rec_have dig; then
    printf '\n'
    rec_ui_heading "REVERSE DNS"
    _rwip_ptr="$(dig +short +time=3 +tries=1 -x "$_rwip_ip" 2>/dev/null | awk 'NF' | head -n4)"
    if [ -n "$_rwip_ptr" ]; then
      _rwip_first=1
      printf '%s\n' "$_rwip_ptr" | while IFS= read -r _rwip_p; do
        [ -z "$_rwip_p" ] && continue
        if [ "$_rwip_first" -eq 1 ]; then
          rec_ui_kv ptr "$_rwip_p"
          _rwip_first=0
        else
          __rec_whois_kv_cont "$_rwip_p"
        fi
      done
    else
      rec_ui_note "no PTR record"
    fi
  fi
}

# Minimal JSON field extractor for the small flat objects ipinfo returns.
# __rec_whois_json_field "<json>" <key>
# Picks the first "key":"value" occurrence and unescapes \" and \\.
__rec_whois_json_field() {
  if rec_have jq; then
    printf '%s' "$1" | jq -r --arg k "$2" '.[$k] // empty' 2>/dev/null
    return
  fi
  printf '%s' "$1" \
    | tr -d '\n' \
    | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | head -n1 \
    | sed -E "s/^\"$2\"[[:space:]]*:[[:space:]]*\"(.*)\"$/\1/" \
    | sed 's/\\"/"/g; s/\\\\/\\/g'
}
