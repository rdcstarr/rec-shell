#!/usr/bin/env bats
#
# Tests for `rec dns` (lib/cli-dns.sh). Stubs `dig` so the output is identical
# on Linux and macOS and never touches a resolver.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$(mktemp -d)"
  mkdir -p "$T/bin"
}
teardown() { rm -rf "$T"; }

dns_in() {
  local shell="$1" os="$2"
  shift 2
  run "$shell" -c "
    export HOME='$T' PATH='$T/bin:/usr/bin:/bin'
    REC_SHELL_DIR='$REPO_ROOT' REC_SHELL_NAME='$shell' REC_UI_PLAIN=1 REC_OS='$os'
    . '$REPO_ROOT/lib/core.sh'
    REC_OS='$os'
    . '$REPO_ROOT/lib/ui.sh'
    . '$REPO_ROOT/lib/cli-dns.sh'
    $*"
}

# A `dig` stub that emits realistic +short output for each record TYPE.
# The TYPE is whichever argument equals A/AAAA/MX/NS/TXT/CNAME/SOA — dig's CLI
# is positional but flag-tolerant, so we just scan all args.
write_fake_dig() {
  cat >"$T/bin/dig" <<'EOF'
#!/bin/sh
type=""
for arg in "$@"; do
  case "$arg" in
    A | AAAA | MX | NS | TXT | CNAME | SOA | PTR | SRV | CAA) type="$arg" ;;
  esac
done
case "$type" in
  A)    printf '93.184.216.34\n' ;;
  AAAA) printf '2606:2800:220:1:248:1893:25c8:1946\n' ;;
  MX)   printf '0 .\n' ;;
  NS)   printf 'a.iana-servers.net.\nb.iana-servers.net.\n' ;;
  TXT)  printf '"v=spf1 -all"\n' ;;
  CNAME) : ;;
  SOA)  printf 'ns.icann.org. noc.dns.icann.org. 2024010101 7200 3600 1209600 3600\n' ;;
  *) : ;;
esac
EOF
  chmod +x "$T/bin/dig"
}

@test "bash: full lookup shows A, AAAA, MX, NS, TXT, SOA rows" {
  write_fake_dig
  dns_in bash linux '__rec_dns_records example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *"A"*"93.184.216.34"* ]]
  [[ "$output" == *"AAAA"*"2606:2800:220"* ]]
  [[ "$output" == *"NS"*"a.iana-servers.net"* ]]
  [[ "$output" == *"NS"*"b.iana-servers.net"* ]]
  [[ "$output" == *"TXT"*"v=spf1"* ]]
  [[ "$output" == *"SOA"*"ns.icann.org"* ]]
  # The TYPE/VALUE header should be present.
  [[ "$output" == *"TYPE"*"VALUE"* ]]
}

@test "bash: single-type lookup (mx) returns just MX" {
  write_fake_dig
  dns_in bash linux '__rec_dns_records example.com mx'
  [ "$status" -eq 0 ]
  [[ "$output" == *"DNS MX: example.com"* ]]
  [[ "$output" == *"0 ."* ]]
  # No table header, no other TYPEs.
  [[ "$output" != *"TYPE"*"VALUE"* ]]
}

@test "bash: type is case-insensitive" {
  write_fake_dig
  dns_in bash linux '__rec_dns_records example.com Ns'
  [ "$status" -eq 0 ]
  [[ "$output" == *"DNS NS: example.com"* ]]
  [[ "$output" == *"a.iana-servers.net"* ]]
}

@test "bash: empty answer for a single type prints a note" {
  write_fake_dig
  dns_in bash linux '__rec_dns_records example.com cname'
  [ "$status" -eq 0 ]
  [[ "$output" == *"no CNAME record"* ]]
}

@test "bash: invalid record type returns exit 2" {
  write_fake_dig
  dns_in bash linux '__rec_dns_records example.com xyz'
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown record type"* ]]
}

@test "bash: missing domain returns exit 2 (non-interactive)" {
  write_fake_dig
  dns_in bash linux '__rec_dns_dispatch'
  [ "$status" -eq 2 ]
}

@test "bash: missing 'dig' binary yields exit 1 + clear error" {
  # macOS / many Linux distros ship dig in /usr/bin, so PATH filtering isn't
  # enough — override rec_have so the module sees dig as absent.
  dns_in bash linux '
    rec_have() { case "$1" in dig) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
    __rec_dns_records example.com'
  [ "$status" -eq 1 ]
  [[ "$output" == *"'dig' is required"* ]]
}

@test "bash: help lists supported record types" {
  dns_in bash linux '__rec_dns_help'
  [ "$status" -eq 0 ]
  [[ "$output" == *"A"*"AAAA"*"MX"*"NS"*"TXT"*"CNAME"*"SOA"* ]]
}
