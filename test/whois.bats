#!/usr/bin/env bats
#
# Tests for `rec whois` (lib/cli-whois.sh). Stubs `whois`, `curl`, and `dig` so
# the tests are network-free and identical on Linux and macOS.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$(mktemp -d)"
  mkdir -p "$T/bin"
}
teardown() { rm -rf "$T"; }

# Source the module with a fake PATH that only sees the stubs we install
# under $T/bin (plus /usr/bin /bin for awk/sed/grep/printf).
whois_in() {
  local shell="$1" os="$2"
  shift 2
  run "$shell" -c "
    export HOME='$T' PATH='$T/bin:/usr/bin:/bin'
    REC_SHELL_DIR='$REPO_ROOT' REC_SHELL_NAME='$shell' REC_UI_PLAIN=1 REC_OS='$os'
    . '$REPO_ROOT/lib/core.sh'
    REC_OS='$os'
    . '$REPO_ROOT/lib/ui.sh'
    . '$REPO_ROOT/lib/cli-whois.sh'
    $*"
}

# --- shared stubs ---------------------------------------------------------

write_fake_whois_domain() {
  cat >"$T/bin/whois" <<'EOF'
#!/bin/sh
# Strip leading "--" to mimic the real `whois -- <target>` invocation.
[ "$1" = "--" ] && shift
target="$1"
case "$target" in
  *available*)
    printf 'No match for "%s".\n' "$target"
    ;;
  example.com)
    cat <<ROWS
Domain Name: EXAMPLE.COM
Registrar: ICANN Registrar
Creation Date: 1995-08-14T04:00:00Z
Updated Date: 2024-08-14T07:01:38Z
Registry Expiry Date: 2025-08-13T04:00:00Z
Domain Status: clientTransferProhibited
Name Server: A.IANA-SERVERS.NET
Name Server: B.IANA-SERVERS.NET
DNSSEC: signedDelegation
ROWS
    ;;
  8.8.8.8)
    cat <<ROWS
NetRange:       8.8.8.0 - 8.8.8.255
CIDR:           8.8.8.0/24
NetName:        LVLT-GOGL-8-8-8
OrgName:        Google LLC
Country:        US
OriginAS:       AS15169
OrgAbuseEmail:  network-abuse@google.com
ROWS
    ;;
  *)
    printf 'No match for "%s".\n' "$target"
    ;;
esac
EOF
  chmod +x "$T/bin/whois"
}

write_fake_curl_geo() {
  cat >"$T/bin/curl" <<'EOF'
#!/bin/sh
# Return canned ipinfo.io JSON regardless of arguments.
cat <<JSON
{
  "ip": "8.8.8.8",
  "hostname": "dns.google",
  "city": "Mountain View",
  "region": "California",
  "country": "US",
  "loc": "37.4056,-122.0775",
  "org": "AS15169 Google LLC",
  "postal": "94043",
  "timezone": "America/Los_Angeles"
}
JSON
EOF
  chmod +x "$T/bin/curl"
}

write_fake_dig_ptr() {
  cat >"$T/bin/dig" <<'EOF'
#!/bin/sh
# Recognize the reverse-lookup form: dig +short ... -x 8.8.8.8
for arg in "$@"; do
  case "$arg" in -x) is_ptr=1 ;; esac
done
[ "${is_ptr:-0}" = 1 ] && printf 'dns.google.\n'
EOF
  chmod +x "$T/bin/dig"
}

# --- tests ----------------------------------------------------------------

@test "bash: parses registrar / expiry / NS from domain whois" {
  write_fake_whois_domain
  whois_in bash linux '__rec_whois_domain example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ICANN Registrar"* ]]
  [[ "$output" == *"2025-08-13"* ]]
  [[ "$output" == *"A.IANA-SERVERS.NET"* ]]
  [[ "$output" == *"B.IANA-SERVERS.NET"* ]]
  [[ "$output" == *"signedDelegation"* ]]
}

@test "bash: 'No match' marks the domain as AVAILABLE" {
  write_fake_whois_domain
  whois_in bash linux '__rec_whois_domain something-available.example'
  [ "$status" -eq 0 ]
  [[ "$output" == *"AVAILABLE"* ]]
}

@test "bash: ip lookup shows whois + geo + reverse DNS" {
  write_fake_whois_domain
  write_fake_curl_geo
  write_fake_dig_ptr
  whois_in bash linux '__rec_whois_ip 8.8.8.8'
  [ "$status" -eq 0 ]
  # whois section
  [[ "$output" == *"Google LLC"* ]]
  [[ "$output" == *"AS15169"* ]]
  [[ "$output" == *"network-abuse@google.com"* ]]
  # geo section (no jq stub on PATH, so the fallback parser is exercised)
  [[ "$output" == *"Mountain View"* ]]
  [[ "$output" == *"America/Los_Angeles"* ]]
  # reverse DNS
  [[ "$output" == *"dns.google"* ]]
}

@test "bash: auto-detect dispatches an IPv4 to the IP path" {
  write_fake_whois_domain
  write_fake_curl_geo
  write_fake_dig_ptr
  whois_in bash linux '__rec_whois_dispatch 8.8.8.8'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Google LLC"* ]]
  [[ "$output" == *"Mountain View"* ]]
}

@test "bash: auto-detect dispatches an IPv6 to the IP path" {
  # Stub `whois` so any IPv6 lookup returns *something* parseable.
  cat >"$T/bin/whois" <<'EOF'
#!/bin/sh
[ "$1" = "--" ] && shift
cat <<ROWS
inet6num: 2606:4700:4700::/48
netname:  CLOUDFLARENET
descr:    Cloudflare, Inc.
country:  US
origin:   AS13335
abuse-mailbox: abuse@cloudflare.com
ROWS
EOF
  chmod +x "$T/bin/whois"
  whois_in bash linux '__rec_whois_dispatch 2606:4700:4700::1111'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cloudflare"* ]]
  [[ "$output" == *"AS13335"* ]]
}

@test "bash: auto-detect routes a non-IP token to the domain path" {
  write_fake_whois_domain
  whois_in bash linux '__rec_whois_dispatch example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ICANN Registrar"* ]]
}

@test "bash: missing target -> error exit 2 (non-interactive)" {
  whois_in bash linux '__rec_whois_dispatch'
  [ "$status" -eq 2 ]
}

@test "bash: missing 'whois' binary -> clear error, exit 1" {
  # macOS ships /usr/bin/whois (and many Linux distros do too), so PATH
  # filtering isn't enough — override rec_have for this run so the module
  # behaves as if `whois` is absent.
  whois_in bash linux '
    rec_have() { case "$1" in whois) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
    __rec_whois_domain example.com'
  [ "$status" -eq 1 ]
  [[ "$output" == *"'whois' is required"* ]]
}

@test "bash: help mentions both target shapes" {
  whois_in bash linux '__rec_whois_help'
  [ "$status" -eq 0 ]
  [[ "$output" == *"domain"* && "$output" == *"ip"* ]]
}

@test "bash: created/expires get a humanized '(X ago)' / '(in X)' suffix" {
  # Past creation date + past expiry date (2025-08-13 is before today).
  write_fake_whois_domain
  whois_in bash linux '__rec_whois_domain example.com'
  [ "$status" -eq 0 ]
  # Creation date from 1995 -> decades in the past.
  [[ "$output" == *"created"*"1995-08-14"*"ago"* ]]
  # Past expiry should be tagged "expired ... ago" (kind=expires branch).
  [[ "$output" == *"expires"*"2025-08-13"*"expired"*"ago"* ]]
}

@test "bash: future expiry renders 'in X' rather than 'ago'" {
  cat >"$T/bin/whois" <<'EOF'
#!/bin/sh
[ "$1" = "--" ] && shift
cat <<ROWS
Domain Name: FUTURE.TEST
Registrar: Test Registrar
Creation Date: 2020-01-01T00:00:00Z
Registry Expiry Date: 2099-01-01T00:00:00Z
Name Server: NS1.FUTURE.TEST
ROWS
EOF
  chmod +x "$T/bin/whois"
  whois_in bash linux '__rec_whois_domain future.test'
  [ "$status" -eq 0 ]
  # Future date -> "in X years"; must NOT carry the "expired" prefix.
  [[ "$output" == *"expires"*"2099-01-01"*"in "* ]]
  [[ "$output" != *"expires"*"expired"* ]]
}

@test "bash: NS continuation lines do not show a stray colon" {
  # The bug was that multi-value fields used `rec_ui_kv ''`, which prints a
  # bare ":" as the continuation label. Continuation values should sit on
  # their own line, prefixed by whitespace only.
  write_fake_whois_domain
  whois_in bash linux '__rec_whois_domain example.com'
  [ "$status" -eq 0 ]
  # The fake whois has two name servers. The second one (B.IANA-SERVERS.NET)
  # must appear on a continuation line whose first non-space char is "B",
  # never ":". grep -E exits non-zero if no matching line exists.
  printf '%s\n' "$output" | grep -Eq '^[[:space:]]+B\.IANA-SERVERS\.NET$'
  # And NEVER a line that starts with ":" followed by an NS hostname.
  ! printf '%s\n' "$output" | grep -Eq '^:[[:space:]]+[A-Z]\.IANA-SERVERS\.NET$'
}

@test "bash: humanize_date returns empty on unparseable input" {
  whois_in bash linux '__rec_whois_humanize_date "not a date" && echo CALLED'
  [ "$status" -eq 0 ]
  # No "ago"/"in"/"today" text — empty function output, only the CALLED sentinel.
  [[ "$output" == *"CALLED"* ]]
  [[ "$output" != *"ago"* && "$output" != *"today"* ]]
}

@test "bash: is_ip recognizes IPv4, IPv6 and rejects domains" {
  whois_in bash linux '__rec_whois_is_ip 1.2.3.4 && echo Y || echo N'
  [[ "$output" == "Y" ]]
  whois_in bash linux '__rec_whois_is_ip 2001:db8::1 && echo Y || echo N'
  [[ "$output" == "Y" ]]
  whois_in bash linux '__rec_whois_is_ip example.com && echo Y || echo N'
  [[ "$output" == "N" ]]
  whois_in bash linux '__rec_whois_is_ip 1.2.3 && echo Y || echo N'
  [[ "$output" == "N" ]]
}
