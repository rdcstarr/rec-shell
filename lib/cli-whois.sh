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

# Extract ALL values for a field, one per line.
__rec_whois_field_all() {
  printf '%s\n' "$1" \
    | grep -i -E "^[[:space:]]*$2[[:space:]]*:" \
    | sed -E 's/^[^:]*:[[:space:]]*//' \
    | tr -d '\r' \
    | awk 'NF && !seen[tolower($0)]++'
}

# rec whois domain <domain>
__rec_whois_domain() {
  _rwd_domain="$1"
  if ! rec_have whois; then
    rec_ui_err "'whois' is required for domain lookup"
    rec_ui_note "install with: brew install whois  /  sudo apt install whois  /  sudo dnf install whois"
    rec_ui_note "or re-run the installer: ./install.sh --tools=whois"
    return 1
  fi

  _rwd_out="$(whois -- "$_rwd_domain" 2>/dev/null)" || _rwd_out=""
  if [ -z "$_rwd_out" ]; then
    rec_ui_err "whois returned no data for '$_rwd_domain'"
    return 1
  fi

  rec_ui_heading "WHOIS: $_rwd_domain"
  rec_ui_kv target "$_rwd_domain"

  # Availability detection — common phrasings across registries.
  if printf '%s\n' "$_rwd_out" \
    | grep -i -E -q 'No match for|NOT FOUND|No Data Found|Domain not found|is free|No entries found|Status: *AVAILABLE|Status: *free'; then
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
  [ -n "$_rwd_created" ] && rec_ui_kv created "$_rwd_created"
  [ -n "$_rwd_updated" ] && rec_ui_kv updated "$_rwd_updated"
  [ -n "$_rwd_expiry" ] && rec_ui_kv expires "$_rwd_expiry"
  [ -n "$_rwd_dnssec" ] && rec_ui_kv dnssec "$_rwd_dnssec"

  if [ -n "$_rwd_status" ]; then
    _rwd_first=1
    printf '%s\n' "$_rwd_status" | while IFS= read -r _rwd_s; do
      [ -z "$_rwd_s" ] && continue
      if [ "$_rwd_first" -eq 1 ]; then
        rec_ui_kv status "$_rwd_s"
        _rwd_first=0
      else
        rec_ui_kv '' "$_rwd_s"
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
        rec_ui_kv '' "$_rwd_n"
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
          rec_ui_kv '' "$_rwip_p"
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
