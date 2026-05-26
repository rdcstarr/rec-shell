#!/usr/bin/env bats
#
# Tests for `rec systemd` (lib/cli-systemd.sh). Focused on dispatch, OS guard,
# and flag parsing — the actual systemctl/journalctl integration is left for
# manual verification on a Linux host.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$(mktemp -d)"
  mkdir -p "$T/bin"
}
teardown() { rm -rf "$T"; }

systemd_in() {
  local shell="$1" os="$2"
  shift 2
  run "$shell" -c "
    export HOME='$T' PATH='$T/bin:/usr/bin:/bin'
    REC_SHELL_DIR='$REPO_ROOT' REC_SHELL_NAME='$shell' REC_UI_PLAIN=1 REC_OS='$os'
    . '$REPO_ROOT/lib/core.sh'
    REC_OS='$os'
    . '$REPO_ROOT/lib/ui.sh'
    . '$REPO_ROOT/lib/cli-systemd.sh'
    $*"
}

@test "bash/mac: dispatch refuses on non-Linux" {
  systemd_in bash mac '__rec_systemd_dispatch status sshd'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Linux-only"* ]]
}

@test "bash/linux: missing systemctl yields a clear error" {
  # Ubuntu CI runners ship /usr/bin/systemctl, so just filtering PATH isn't
  # enough — override rec_have so the module behaves as if systemctl is absent.
  systemd_in bash linux '
    rec_have() { case "$1" in systemctl) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
    __rec_systemd_dispatch status sshd'
  [ "$status" -ne 0 ]
  [[ "$output" == *"systemctl"* ]]
}

@test "bash/linux: status requires a unit argument" {
  printf '#!/bin/sh\nexit 0\n' >"$T/bin/systemctl"
  chmod +x "$T/bin/systemctl"
  systemd_in bash linux '__rec_systemd_dispatch status'
  [ "$status" -eq 2 ]
}

@test "bash/linux: start with a stub systemctl prints the call" {
  cat >"$T/bin/systemctl" <<'EOF'
#!/bin/sh
echo "SYSTEMCTL: $*"
EOF
  chmod +x "$T/bin/systemctl"
  # Run as already-root so no sudo is involved; SC happens to honor id -u
  # from `whoami`, but `id -u` itself isn't stubbable here. Instead pass
  # --no-sudo to skip the escalation path.
  systemd_in bash linux '__rec_systemd_dispatch start --no-sudo nginx'
  [ "$status" -eq 0 ]
  [[ "$output" == *"SYSTEMCTL: start -- nginx"* ]]
}

@test "bash/linux: help mentions the read-only and state-changing verbs" {
  systemd_in bash linux '__rec_systemd_help'
  [[ "$output" == *"status"* && "$output" == *"start"* && "$output" == *"logs"* && "$output" == *"list"* ]]
}
