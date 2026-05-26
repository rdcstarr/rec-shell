#!/usr/bin/env bats
#
# Tests for `rec port` (lib/cli-port.sh). Stubs `ss` (linux) and `lsof` (mac)
# so the port-listing behavior is deterministic regardless of what's actually
# listening on the test host.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$(mktemp -d)"
  mkdir -p "$T/bin"
}
teardown() { rm -rf "$T"; }

port_in() {
  local shell="$1" os="$2"
  shift 2
  run "$shell" -c "
    export HOME='$T' PATH='$T/bin:/usr/bin:/bin'
    REC_SHELL_DIR='$REPO_ROOT' REC_SHELL_NAME='$shell' REC_UI_PLAIN=1 REC_OS='$os'
    . '$REPO_ROOT/lib/core.sh'
    REC_OS='$os'
    . '$REPO_ROOT/lib/ui.sh'
    . '$REPO_ROOT/lib/cli-port.sh'
    $*"
}

# Fake ss output covering a TCP+UDP listener with both pid + name fields.
write_fake_ss() {
  cat >"$T/bin/ss" <<'EOF'
#!/bin/sh
# Minimal output matching what `ss -Htulnp` produces.
cat <<ROWS
tcp   LISTEN 0      128                0.0.0.0:80           0.0.0.0:*    users:(("nginx",pid=1234,fd=6))
udp   UNCONN 0      0                  0.0.0.0:53           0.0.0.0:*    users:(("dnsmasq",pid=5678,fd=4))
ROWS
EOF
  chmod +x "$T/bin/ss"
}

@test "bash/linux: list shows ports + pid + process from ss" {
  write_fake_ss
  port_in bash linux '__rec_port_list'
  [ "$status" -eq 0 ]
  [[ "$output" == *"nginx"* ]]
  [[ "$output" == *"1234"* ]]
  [[ "$output" == *"80"* ]]
  [[ "$output" == *"dnsmasq"* ]]
  [[ "$output" == *"53"* ]]
}

@test "bash/linux: free returns 1 when port is in use" {
  write_fake_ss
  port_in bash linux '__rec_port_free 80'
  [ "$status" -eq 1 ]
}

@test "bash/linux: free returns 0 when port is unused" {
  write_fake_ss
  port_in bash linux '__rec_port_free 65530'
  [ "$status" -eq 0 ]
}

@test "bash: free rejects non-numeric input with exit 2" {
  port_in bash linux '__rec_port_free abc'
  [ "$status" -eq 2 ]
}

@test "bash: free without an argument returns 2" {
  port_in bash linux '__rec_port_free'
  [ "$status" -eq 2 ]
}

@test "bash: unknown subcommand returns 2" {
  port_in bash linux '__rec_port_dispatch bogus'
  [ "$status" -eq 2 ]
}

@test "bash: help mentions all three verbs" {
  port_in bash linux '__rec_port_help'
  [[ "$output" == *"list"* && "$output" == *"kill"* && "$output" == *"free"* ]]
}
