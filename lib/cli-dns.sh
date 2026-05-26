# shellcheck shell=bash
#
# lib/cli-dns.sh — the `rec dns` command group. Lazy-loaded by lib/cli.sh on
# the first `rec dns ...`. Thin wrapper around `dig +short` with a uniform
# tabular layout for the common record types.
#
#   rec dns <domain>            A, AAAA, MX, NS, TXT, CNAME, SOA in a table
#   rec dns <domain> <type>     single record type (case-insensitive)
#
# Falls back to a clear error when `dig` is not installed.

__rec_dns_dispatch() {
  _rd_arg="${1:-}"
  if [ -z "$_rd_arg" ]; then
    if rec_ui_interactive_load && __rec_ui_interactive; then
      _rd_arg="$(rec_ui_input 'Domain')"
      [ -z "$_rd_arg" ] && return 0
      set -- "$_rd_arg"
    else
      rec_ui_err "rec dns: <domain> is required"
      printf '\n' >&2
      __rec_dns_help >&2
      return 2
    fi
  fi
  case "$_rd_arg" in
    help | --help | -h)
      __rec_dns_help
      return 0
      ;;
  esac
  __rec_dns_records "$@"
}

__rec_dns_help() {
  cat <<'EOF'
rec dns — DNS record lookup (uses `dig`)

Usage: rec dns <domain> [type]

Without a type, queries the common records and prints them as a table:
  A, AAAA, MX, NS, TXT, CNAME, SOA

With a type, queries only that record type. Accepted types (case-insensitive):
  A AAAA MX NS TXT CNAME SOA PTR SRV CAA

Examples:
  rec dns example.com
  rec dns example.com mx
  rec dns example.com txt
EOF
}

# Validate the requested record type. Echoes the upper-case form on success.
__rec_dns_normalize_type() {
  _rdn_t="$1"
  # POSIX upper-case via tr (works under bash and zsh).
  _rdn_t="$(printf '%s' "$_rdn_t" | tr '[:lower:]' '[:upper:]')"
  case "$_rdn_t" in
    A | AAAA | MX | NS | TXT | CNAME | SOA | PTR | SRV | CAA)
      printf '%s' "$_rdn_t"
      return 0
      ;;
  esac
  return 1
}

# rec dns <domain> [type]
__rec_dns_records() {
  _rdr_domain="$1"
  _rdr_type="${2:-}"
  if ! rec_have dig; then
    rec_ui_err "'dig' is required for DNS lookup"
    rec_ui_note "install with: sudo apt install dnsutils  /  sudo dnf install bind-utils  /  sudo pacman -S bind"
    rec_ui_note "or re-run the installer: ./install.sh --tools=dig"
    return 1
  fi

  if [ -n "$_rdr_type" ]; then
    _rdr_type="$(__rec_dns_normalize_type "$_rdr_type")" || {
      rec_ui_err "rec dns: unknown record type '$2'"
      rec_ui_note "valid: A AAAA MX NS TXT CNAME SOA PTR SRV CAA"
      return 2
    }
    rec_ui_heading "DNS $_rdr_type: $_rdr_domain"
    _rdr_out="$(dig +short +time=3 +tries=1 "$_rdr_type" "$_rdr_domain" 2>/dev/null | awk 'NF')"
    if [ -z "$_rdr_out" ]; then
      rec_ui_note "no $_rdr_type record"
      return 0
    fi
    printf '%s\n' "$_rdr_out"
    return 0
  fi

  rec_ui_heading "DNS: $_rdr_domain"
  # Table: TYPE\tVALUE. Multi-line answers (e.g. multiple A records) each get
  # their own row. Empty types are skipped. Columnated like rec port list.
  {
    printf 'TYPE\tVALUE\n'
    for _rdr_t in A AAAA CNAME MX NS TXT SOA; do
      dig +short +time=3 +tries=1 "$_rdr_t" "$_rdr_domain" 2>/dev/null \
        | awk -v t="$_rdr_t" 'NF { printf "%s\t%s\n", t, $0 }'
    done
  } | column -t -s '	'
}
