#!/usr/bin/env bats
#
# Tests for `rec ip` (lib/cli-ip.sh). Stubs `curl`, `ip`, `ifconfig`, `route`,
# and `ipconfig` so the tests don't touch the network and behave the same on
# Linux and macOS.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$(mktemp -d)"
  mkdir -p "$T/bin"
}
teardown() { rm -rf "$T"; }

# Source the module with a fake PATH containing the requested stubs.
ip_in() {
  local shell="$1" os="$2"
  shift 2
  run "$shell" -c "
    export HOME='$T' PATH='$T/bin:/usr/bin:/bin'
    REC_SHELL_DIR='$REPO_ROOT' REC_SHELL_NAME='$shell' REC_UI_PLAIN=1 REC_OS='$os'
    . '$REPO_ROOT/lib/core.sh'
    REC_OS='$os'
    . '$REPO_ROOT/lib/ui.sh'
    . '$REPO_ROOT/lib/cli-ip.sh'
    $*"
}

@test "bash/linux: public IP comes from curl stub" {
  printf '#!/bin/sh\nprintf "203.0.113.7\\n"\n' >"$T/bin/curl"
  chmod +x "$T/bin/curl"
  ip_in bash linux '__rec_ip_public'
  [ "$status" -eq 0 ]
  [[ "$output" == *"203.0.113.7"* ]]
}

@test "bash/linux: all providers failing yields an error" {
  # Stub curl to always fail so no real network is reached and none of the
  # three providers can return an IP.
  printf '#!/bin/sh\nexit 7\n' >"$T/bin/curl"
  chmod +x "$T/bin/curl"
  ip_in bash linux '__rec_ip_public'
  [ "$status" -ne 0 ]
  [[ "$output" == *"public-IP provider"* ]]
}

@test "bash/linux: local IP parsed from \`ip route get\`" {
  cat >"$T/bin/ip" <<'EOF'
#!/bin/sh
case "$*" in
  "route get 1.1.1.1") printf "1.1.1.1 via 192.168.1.1 dev eth0 src 192.168.1.42 uid 1000\n" ;;
  *) printf "" ;;
esac
EOF
  chmod +x "$T/bin/ip"
  ip_in bash linux '__rec_ip_local'
  [ "$status" -eq 0 ]
  [[ "$output" == *"192.168.1.42"* ]]
}

@test "bash/mac: local IP via route + ipconfig" {
  cat >"$T/bin/route" <<'EOF'
#!/bin/sh
printf "   interface: en0\n"
EOF
  cat >"$T/bin/ipconfig" <<'EOF'
#!/bin/sh
[ "$1" = "getifaddr" ] && printf "10.0.0.42\n"
EOF
  chmod +x "$T/bin/route" "$T/bin/ipconfig"
  ip_in bash mac '__rec_ip_local'
  [ "$status" -eq 0 ]
  [[ "$output" == *"10.0.0.42"* ]]
}

@test "bash: help is non-empty and lists subcommands" {
  ip_in bash mac '__rec_ip_help'
  [ "$status" -eq 0 ]
  [[ "$output" == *"public"* && "$output" == *"local"* && "$output" == *"all"* ]]
}

@test "bash: unknown subcommand returns 2" {
  ip_in bash mac '__rec_ip_dispatch bogus'
  [ "$status" -eq 2 ]
}
