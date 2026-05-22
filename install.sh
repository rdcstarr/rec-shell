#!/usr/bin/env bash
#
# rec-shell installer.
#
#   curl -fsSL https://rec-shell.recwebnetwork.com/install | bash
#   curl -fsSL https://rec-shell.recwebnetwork.com/install | sudo bash -s -- --system
#
# Clones the repo into a directory and adds ONE loader line to your shell rc.
# It never overwrites your rc; the line is idempotent and your rc is backed up
# once. Re-running updates the checkout and is a safe no-op for the rc.

set -euo pipefail

REPO_URL="${REC_SHELL_REPO_URL:-https://github.com/rdcstarr/rec-shell.git}"
REF="${REC_SHELL_REF:-}" # empty => latest tag (fallback: default branch)
MODE=user
UNATTENDED=0
INSTALL_OMP=auto # auto | yes | no
TARGET_DIR="${REC_SHELL_DIR:-}"
MARKER="# rec-shell"

usage() {
  cat <<'EOF'
Usage: install.sh [--user|--system] [--unattended] [--no-omp]
                  [--dir DIR] [--ref REF]

  --user        Install for the current user in ~/.rec-shell (default).
  --system      Install system-wide in /opt/rec-shell and add the loader to
                /etc rc files (all users). Must run as root.
  --unattended  Never prompt; auto-install oh-my-posh if missing.
  --no-omp      Do not install oh-my-posh.
  --dir DIR     Install into DIR instead of the default.
  --ref REF     Check out a specific tag/branch/commit (default: latest tag).

Environment overrides: REC_SHELL_REPO_URL, REC_SHELL_REF, REC_SHELL_DIR
EOF
}

# --- pretty output ---------------------------------------------------------
if [ -t 1 ]; then
  C_B="$(printf '\033[1m')" C_G="$(printf '\033[32m')" C_Y="$(printf '\033[33m')" C_R="$(printf '\033[31m')" C_0="$(printf '\033[0m')"
else
  C_B="" C_G="" C_Y="" C_R="" C_0=""
fi
log() { printf '%s==>%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
err() { printf '%s[error]%s %s\n' "$C_R" "$C_0" "$*" >&2; }
die() {
  err "$*"
  exit 1
}

# --- parse args ------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --user) MODE=user ;;
    --system) MODE=system ;;
    --unattended | -y) UNATTENDED=1 ;;
    --no-omp) INSTALL_OMP=no ;;
    --dir)
      shift
      TARGET_DIR="${1:-}"
      ;;
    --dir=*) TARGET_DIR="${1#*=}" ;;
    --ref)
      shift
      REF="${1:-}"
      ;;
    --ref=*) REF="${1#*=}" ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      err "unknown option: $1"
      usage >&2
      exit 2
      ;;
  esac
  shift
done

# --- detect OS -------------------------------------------------------------
case "$(uname -s)" in
  Darwin) OS=mac ;;
  Linux) OS=linux ;;
  *) die "unsupported OS: $(uname -s)" ;;
esac

# --- target dir + privileges ----------------------------------------------
if [ "$MODE" = system ]; then
  TARGET_DIR="${TARGET_DIR:-/opt/rec-shell}"
  if [ "$(id -u)" -ne 0 ]; then
    die "System install must run as root:
  curl -fsSL https://rec-shell.recwebnetwork.com/install | sudo bash -s -- --system"
  fi
else
  TARGET_DIR="${TARGET_DIR:-$HOME/.rec-shell}"
fi

# --- helpers ---------------------------------------------------------------
ensure_git() {
  command -v git >/dev/null 2>&1 && return 0
  if [ "$(id -u)" -ne 0 ]; then
    die "git is required. Install it and re-run."
  fi
  log "Installing git..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y git
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y git
  elif command -v yum >/dev/null 2>&1; then
    yum install -y git
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache git
  else
    die "git not found and no known package manager available."
  fi
}

clone_or_update() {
  if [ -d "$TARGET_DIR/.git" ]; then
    log "Updating existing checkout in $TARGET_DIR"
    git -C "$TARGET_DIR" remote set-url origin "$REPO_URL" 2>/dev/null || true
    git -C "$TARGET_DIR" fetch --tags --prune origin
  else
    log "Cloning $REPO_URL -> $TARGET_DIR"
    mkdir -p "$(dirname "$TARGET_DIR")"
    git clone --quiet "$REPO_URL" "$TARGET_DIR"
  fi

  local ref="$REF"
  if [ -z "$ref" ]; then
    ref="$(git -C "$TARGET_DIR" describe --tags "$(git -C "$TARGET_DIR" rev-list --tags --max-count=1 2>/dev/null)" 2>/dev/null || true)"
  fi
  if [ -n "$ref" ]; then
    log "Checking out $ref"
    git -C "$TARGET_DIR" checkout -q "$ref" 2>/dev/null \
      || git -C "$TARGET_DIR" checkout -q -B "$ref" "origin/$ref" 2>/dev/null \
      || warn "could not check out '$ref'; staying on default branch"
  fi
}

# Representation of the install dir to write into the rc file.
line_dir_repr() {
  if [ "$MODE" = user ] && [ "$TARGET_DIR" = "$HOME/.rec-shell" ]; then
    # Intentionally literal: $HOME must be expanded by the user's shell at
    # startup, not here at install time.
    # shellcheck disable=SC2016
    printf '$HOME/.rec-shell'
  else
    printf '%s' "$TARGET_DIR"
  fi
}

backup_once() {
  local rc="$1" bak="$1.rec-shell.bak"
  [ -f "$rc" ] || return 0
  [ -f "$bak" ] || cp -p "$rc" "$bak"
}

ensure_loader_in_rc() {
  local rc="$1" dir
  dir="$(line_dir_repr)"
  if [ -f "$rc" ] && grep -qF "$MARKER" "$rc"; then
    log "Loader already present in $rc"
    return 0
  fi
  mkdir -p "$(dirname "$rc")"
  backup_once "$rc"
  # keep a clean separation from existing content
  if [ -f "$rc" ] && [ -n "$(tail -c1 "$rc" 2>/dev/null)" ]; then
    printf '\n' >>"$rc"
  fi
  printf '%s\n[ -f "%s/rec-shell.sh" ] && . "%s/rec-shell.sh"\n' "$MARKER" "$dir" "$dir" >>"$rc"
  log "Added loader to $rc"
}

system_rc_for() {
  case "$1" in
    zsh) if [ -d /etc/zsh ]; then echo /etc/zsh/zshrc; else echo /etc/zshrc; fi ;;
    bash) if [ -f /etc/bashrc ] && [ ! -f /etc/bash.bashrc ]; then echo /etc/bashrc; else echo /etc/bash.bashrc; fi ;;
  esac
}

install_loader_lines() {
  local shells="" s rc
  command -v zsh >/dev/null 2>&1 && shells="$shells zsh"
  command -v bash >/dev/null 2>&1 && shells="$shells bash"
  [ -n "$shells" ] || shells="zsh bash"
  for s in $shells; do
    if [ "$MODE" = system ]; then
      rc="$(system_rc_for "$s")"
    else
      [ "$s" = zsh ] && rc="$HOME/.zshrc" || rc="$HOME/.bashrc"
    fi
    [ -n "$rc" ] && ensure_loader_in_rc "$rc"
  done
}

ensure_omp() {
  [ "$INSTALL_OMP" = no ] && return 0
  command -v oh-my-posh >/dev/null 2>&1 && {
    log "oh-my-posh already installed"
    return 0
  }
  if [ "$UNATTENDED" -eq 0 ]; then
    printf 'Install oh-my-posh now (required for the prompt)? [y/N] '
    local ans=n
    read -r ans </dev/tty 2>/dev/null || ans=n
    case "$ans" in
      y | Y | yes) ;;
      *)
        warn "Skipping oh-my-posh; the prompt will be inactive until it is installed."
        return 0
        ;;
    esac
  fi
  log "Installing oh-my-posh..."
  if [ "$OS" = mac ]; then
    if command -v brew >/dev/null 2>&1; then
      brew install jandedobbeleer/oh-my-posh/oh-my-posh
    else
      warn "Homebrew not found; install oh-my-posh manually: https://ohmyposh.dev"
    fi
  else
    local bindir=/usr/local/bin
    [ "$(id -u)" -ne 0 ] && bindir="$HOME/.local/bin"
    mkdir -p "$bindir"
    curl -fsSL https://ohmyposh.dev/install.sh | bash -s -- -d "$bindir" || warn "oh-my-posh install failed; install it manually."
  fi
}

# --- run -------------------------------------------------------------------
log "Installing rec-shell (${C_B}${MODE}${C_0}) into ${C_B}${TARGET_DIR}${C_0}"
ensure_git
clone_or_update
install_loader_lines
ensure_omp

VER="$(head -n1 "$TARGET_DIR/VERSION" 2>/dev/null || echo '?')"
printf '\n%s✓ rec-shell %s installed.%s\n' "$C_G" "$VER" "$C_0"
printf 'Restart your shell, or run: %sexec %s -l%s\n' "$C_B" "${SHELL:-bash}" "$C_0"
printf 'Then check it with: %srec-shell doctor%s\n' "$C_B" "$C_0"
