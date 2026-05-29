#!/usr/bin/env bats
#
# Tests for `rec domain` (lib/cli-domain.sh). Stubs `whois` and `curl` so the
# tests are network-free and identical on Linux and macOS.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$(mktemp -d)"
  mkdir -p "$T/bin"
}
teardown() { rm -rf "$T"; }

# Source the modules with a fake PATH that only sees the stubs we install
# under $T/bin (plus /usr/bin /bin for awk/sed/grep/printf).
domain_in() {
  local shell="$1" os="$2"
  shift 2
  run "$shell" -c "
    export HOME='$T' PATH='$T/bin:/usr/bin:/bin'
    REC_SHELL_DIR='$REPO_ROOT' REC_SHELL_NAME='$shell' REC_UI_PLAIN=1 REC_OS='$os'
    . '$REPO_ROOT/lib/core.sh'
    REC_OS='$os'
    . '$REPO_ROOT/lib/ui.sh'
    . '$REPO_ROOT/lib/cli-whois.sh'
    . '$REPO_ROOT/lib/cli-domain.sh'
    $*"
}

# --- shared stubs ---------------------------------------------------------

# Routes the RDAP URL to a canned HTTP status. Looks at args for the URL.
write_fake_curl_router() {
  cat >"$T/bin/curl" <<'EOF'
#!/bin/sh
url=""
for a in "$@"; do
  case "$a" in https://*) url="$a" ;; esac
done
d="${url##*/domain/}"
case "$d" in
  *.available.test) code=404 ;;
  *.taken.test|example.com|google.com) code=200 ;;
  *.error.test) code=500 ;;
  *) code=404 ;;
esac
printf '%s' "$code"
EOF
  chmod +x "$T/bin/curl"
}

# Always-404 curl — used for scan tests where we want every candidate to be
# classified AVAILABLE.
write_fake_curl_404() {
  cat >"$T/bin/curl" <<'EOF'
#!/bin/sh
printf '%s' '404'
EOF
  chmod +x "$T/bin/curl"
}

write_fake_whois_router() {
  cat >"$T/bin/whois" <<'EOF'
#!/bin/sh
[ "$1" = "--" ] && shift
target="$1"
case "$target" in
  *.available.test)
    printf 'No match for "%s".\n' "$target"
    ;;
  *.taken.test|example.com)
    cat <<ROWS
Domain Name: ${target}
Registrar: Test Registrar
Creation Date: 2020-01-01T00:00:00Z
ROWS
    ;;
  *)
    printf 'No match for "%s".\n' "$target"
    ;;
esac
EOF
  chmod +x "$T/bin/whois"
}

# --- check: tests ---------------------------------------------------------

@test "bash: check returns 0 AVAILABLE on RDAP 404" {
  write_fake_curl_router
  domain_in bash linux '__rec_domain_check foo.available.test'
  [ "$status" -eq 0 ]
  [[ "$output" == *"AVAILABLE"* ]]
  [[ "$output" == *"foo.available.test"* ]]
  [[ "$output" == *"rdap"* ]]
}

@test "bash: check returns 1 REGISTERED on RDAP 200" {
  write_fake_curl_router
  domain_in bash linux '__rec_domain_check example.com'
  [ "$status" -eq 1 ]
  [[ "$output" == *"REGISTERED"* ]]
  [[ "$output" == *"example.com"* ]]
}

@test "bash: check falls back to whois on RDAP error and finds AVAILABLE" {
  # RDAP returns 500 for *.error.test -> falls through to whois.
  write_fake_curl_router
  write_fake_whois_router
  domain_in bash linux '__rec_domain_check foo.available.test'
  [ "$status" -eq 0 ]
  [[ "$output" == *"AVAILABLE"* ]]
}

@test "bash: check returns 2 UNKNOWN when RDAP errors and no whois" {
  write_fake_curl_router
  domain_in bash linux '
    rec_have() { case "$1" in whois) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
    __rec_domain_check foo.error.test'
  [ "$status" -eq 2 ]
  [[ "$output" == *"UNKNOWN"* ]]
}

@test "bash: check rejects domain without a dot" {
  domain_in bash linux '__rec_domain_check noTLD'
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid domain"* ]]
}

@test "bash: check rejects domain with invalid chars" {
  domain_in bash linux '__rec_domain_check "bad domain.com"'
  [ "$status" -eq 2 ]
}

@test "bash: check lowercases input" {
  write_fake_curl_router
  domain_in bash linux '__rec_domain_check EXAMPLE.COM'
  [ "$status" -eq 1 ]
  [[ "$output" == *"example.com"* ]]
}

# --- alphabet parser ------------------------------------------------------

@test "bash: parse_alphabet expands a-z to 26 chars" {
  domain_in bash linux 'a="$(__rec_domain_parse_alphabet a-z)"; echo "${#a}"'
  [ "$output" = "26" ]
}

@test "bash: parse_alphabet expands a-z0-9 to 36 chars" {
  domain_in bash linux 'a="$(__rec_domain_parse_alphabet a-z0-9)"; echo "${#a}"'
  [ "$output" = "36" ]
}

@test "bash: parse_alphabet keeps literal chars" {
  domain_in bash linux 'a="$(__rec_domain_parse_alphabet abcd)"; echo "$a"'
  [ "$output" = "abcd" ]
}

@test "bash: parse_alphabet de-duplicates" {
  domain_in bash linux 'a="$(__rec_domain_parse_alphabet abcabc)"; echo "$a"'
  [ "$output" = "abc" ]
}

@test "bash: parse_alphabet expands A-Z" {
  domain_in bash linux 'a="$(__rec_domain_parse_alphabet A-Z)"; echo "${#a}"'
  [ "$output" = "26" ]
}

# --- generator ------------------------------------------------------------

@test "bash: gen produces N^L candidates" {
  domain_in bash linux '__rec_domain_gen abc 2 | wc -l | tr -d " "'
  [ "$output" = "9" ]
}

@test "bash: gen emits in lex order" {
  domain_in bash linux '__rec_domain_gen abc 2'
  expected="aa
ab
ac
ba
bb
bc
ca
cb
cc"
  [ "$output" = "$expected" ]
}

@test "bash: gen len 3 over a-z produces 17576 candidates" {
  domain_in bash linux 'a="$(__rec_domain_parse_alphabet a-z)"; __rec_domain_gen "$a" 3 | wc -l | tr -d " "'
  [ "$output" = "17576" ]
}

# --- scan flag parsing ----------------------------------------------------

@test "bash: scan rejects missing --len" {
  domain_in bash linux '__rec_domain_dispatch scan ro'
  [ "$status" -eq 2 ]
}

@test "bash: scan rejects missing tld" {
  domain_in bash linux '__rec_domain_dispatch scan --len 2'
  [ "$status" -eq 2 ]
}

@test "bash: scan rejects invalid tld with space" {
  domain_in bash linux '__rec_domain_dispatch scan "bad tld" --len 2'
  [ "$status" -eq 2 ]
}

@test "bash: scan rejects non-positive --len" {
  domain_in bash linux '__rec_domain_dispatch scan ro --len abc'
  [ "$status" -eq 2 ]
}

@test "bash: scan rejects unknown flag" {
  domain_in bash linux '__rec_domain_dispatch scan ro --len 2 --wibble'
  [ "$status" -eq 2 ]
}

@test "bash: scan --dry-run prints the candidate list and exits 0" {
  domain_in bash linux '__rec_domain_dispatch scan ro --len 2 --alphabet abc --dry-run | wc -l | tr -d " "'
  [ "$output" = "9" ]
}

# --- scan end-to-end ------------------------------------------------------

@test "bash: scan writes state file with header (small alphabet)" {
  write_fake_curl_404
  domain_in bash linux '__rec_domain_dispatch scan ro --len 1 --alphabet ab --jobs 2 >/dev/null; cat "$HOME/.cache/rec-shell/domain/scans/ro-1-ab.state"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"# rec-domain-scan v1"* ]]
  [[ "$output" == *"# tld: ro"* ]]
  [[ "$output" == *"# length: 1"* ]]
  [[ "$output" == *"# alphabet: ab"* ]]
  [[ "$output" == *"# total: 2"* ]]
  [[ "$output" == *"a	AVAILABLE	rdap"* ]]
  [[ "$output" == *"b	AVAILABLE	rdap"* ]]
}

@test "bash: scan streams AVAILABLE results to stdout" {
  write_fake_curl_404
  domain_in bash linux '__rec_domain_dispatch scan ro --len 1 --alphabet ab --jobs 2'
  [ "$status" -eq 0 ]
  [[ "$output" == *"a.ro"* ]]
  [[ "$output" == *"b.ro"* ]]
}

@test "bash: scan --out appends AVAILABLE names to a file" {
  write_fake_curl_404
  domain_in bash linux '__rec_domain_dispatch scan ro --len 1 --alphabet ab --jobs 2 --out "$HOME/found.txt" >/dev/null; sort "$HOME/found.txt"'
  [ "$status" -eq 0 ]
  expected="a.ro
b.ro"
  [ "$output" = "$expected" ]
}

@test "bash: scan resumes from existing state (skips done candidates)" {
  mkdir -p "$T/.cache/rec-shell/domain/scans"
  cat >"$T/.cache/rec-shell/domain/scans/ro-1-ab.state" <<'EOF'
# rec-domain-scan v1
# tld: ro
# length: 1
# alphabet: ab
# started: 2026-05-29T00:00:00Z
# total: 2
a	REGISTERED	rdap
EOF
  write_fake_curl_404
  domain_in bash linux '__rec_domain_dispatch scan ro --len 1 --alphabet ab --jobs 2 2>&1'
  [ "$status" -eq 0 ]
  [[ "$output" == *"resuming from state"* ]]
  # Final state file has the original REGISTERED 'a' plus AVAILABLE 'b'.
  state="$T/.cache/rec-shell/domain/scans/ro-1-ab.state"
  count="$(grep -c '^[^#]' "$state")"
  [ "$count" = "2" ]
  grep -q '^a	REGISTERED' "$state"
  grep -q '^b	AVAILABLE' "$state"
}

@test "bash: scan --reset wipes existing state and starts fresh" {
  mkdir -p "$T/.cache/rec-shell/domain/scans"
  cat >"$T/.cache/rec-shell/domain/scans/ro-1-ab.state" <<'EOF'
# rec-domain-scan v1
# tld: ro
# length: 1
# alphabet: ab
# started: 2026-05-29T00:00:00Z
# total: 2
a	REGISTERED	rdap
b	REGISTERED	rdap
EOF
  write_fake_curl_404
  domain_in bash linux '__rec_domain_dispatch scan ro --len 1 --alphabet ab --jobs 2 --reset 2>&1'
  [ "$status" -eq 0 ]
  state="$T/.cache/rec-shell/domain/scans/ro-1-ab.state"
  # All entries should now reflect the fresh AVAILABLE run.
  count="$(grep -c '^[^#]' "$state")"
  [ "$count" = "2" ]
  grep -q '^a	AVAILABLE' "$state"
  grep -q '^b	AVAILABLE' "$state"
}

@test "bash: scan refuses to resume when state header mismatches" {
  mkdir -p "$T/.cache/rec-shell/domain/scans"
  cat >"$T/.cache/rec-shell/domain/scans/ro-1-ab.state" <<'EOF'
# rec-domain-scan v1
# tld: com
# length: 1
# alphabet: ab
# started: 2026-05-29T00:00:00Z
# total: 2
a	REGISTERED	rdap
EOF
  write_fake_curl_404
  domain_in bash linux '__rec_domain_dispatch scan ro --len 1 --alphabet ab --jobs 2 2>&1'
  [ "$status" -eq 2 ]
}

@test "bash: scan in --rdap mode skips whois entirely" {
  # Set whois to a script that would *fail* the test if called.
  cat >"$T/bin/whois" <<'EOF'
#!/bin/sh
echo "WHOIS-WAS-CALLED" >&2
exit 1
EOF
  chmod +x "$T/bin/whois"
  # RDAP returns 500 -> normally would fall back to whois. With --rdap, it
  # must not.
  cat >"$T/bin/curl" <<'EOF'
#!/bin/sh
printf '%s' '500'
EOF
  chmod +x "$T/bin/curl"
  domain_in bash linux '__rec_domain_dispatch scan ro --len 1 --alphabet ab --jobs 2 --rdap 2>&1'
  [ "$status" -eq 0 ]
  [[ "$output" != *"WHOIS-WAS-CALLED"* ]]
}

# --- misc -----------------------------------------------------------------

@test "bash: help mentions both subcommands" {
  domain_in bash linux '__rec_domain_help'
  [ "$status" -eq 0 ]
  [[ "$output" == *"check"* ]]
  [[ "$output" == *"scan"* ]]
}

@test "bash: missing subcommand exits 2 with help on stderr" {
  domain_in bash linux '__rec_domain_dispatch'
  [ "$status" -eq 2 ]
}

# --- zsh smoke tests ------------------------------------------------------

@test "zsh: parse_alphabet works under zsh" {
  domain_in zsh linux 'a="$(__rec_domain_parse_alphabet a-z0-9)"; echo "${#a}"'
  [ "$output" = "36" ]
}

@test "zsh: gen produces correct count" {
  domain_in zsh linux '__rec_domain_gen abc 2 | wc -l | tr -d " "'
  [ "$output" = "9" ]
}

@test "zsh: check returns AVAILABLE for a 404 response" {
  write_fake_curl_router
  domain_in zsh linux '__rec_domain_check foo.available.test'
  [ "$status" -eq 0 ]
  [[ "$output" == *"AVAILABLE"* ]]
}

@test "zsh: scan writes state file" {
  write_fake_curl_404
  domain_in zsh linux '__rec_domain_dispatch scan ro --len 1 --alphabet ab --jobs 2 >/dev/null'
  [ "$status" -eq 0 ]
  [ -f "$T/.cache/rec-shell/domain/scans/ro-1-ab.state" ]
}

@test "zsh: scan --dry-run works" {
  domain_in zsh linux '__rec_domain_dispatch scan ro --len 2 --alphabet ab --dry-run | wc -l | tr -d " "'
  [ "$output" = "4" ]
}
