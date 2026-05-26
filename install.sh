#!/usr/bin/env bash
#
# rec-shell installer.
#
#   curl -fsSL https://rec-shell.recwebnetwork.com/install.sh | bash
#   curl -fsSL https://rec-shell.recwebnetwork.com/install.sh | sudo bash -s -- --system
#
# Clones the repo into a directory and adds ONE loader line to your shell rc.
# It never overwrites your rc; the line is idempotent and your rc is backed up
# once. Re-running updates the checkout and is a safe no-op for the rc.

set -euo pipefail

REPO_URL="${REC_SHELL_REPO_URL:-https://github.com/rdcstarr/rec-shell.git}"
REF="${REC_SHELL_REF:-}" # empty => latest tag (fallback: default branch)
MODE=user
UNATTENDED=0
INSTALL_OMP=auto    # auto | yes | no
INSTALL_ZOXIDE=auto # auto | yes | no
TARGET_DIR="${REC_SHELL_DIR:-}"
MARKER="# rec-shell"

# Modern CLI tools selection — processed in install_tools_all below. zsh
# plugins come last so an interrupted install still leaves the binary tools
# usable.
TOOLS_ALLOW=""     # --tools=a,b,c (empty = no allowlist)
TOOLS_DENY=""      # --without=a,b,c
INSTALL_TOOLS=auto # auto | none  (--no-tools sets none)
TOOLS_ONLY=0

usage() {
  cat <<'EOF'
Usage: install.sh [--user|--system] [--unattended] [--no-omp] [--no-zoxide]
                  [--no-tools|--tools=LIST|--without=LIST]
                  [--dir DIR] [--ref REF]

  --user             Install for the current user in ~/.rec-shell (default).
  --system           Install system-wide in /opt/rec-shell and add the loader
                     to /etc rc files (all users). Must run as root.
  --unattended       Never prompt; auto-install everything.
  --no-omp           Do not install oh-my-posh.
  --no-zoxide        Do not install zoxide (the `z` smart-cd command).
  --no-tools         Skip ALL of the modern CLI tools below.
  --tools-only       Only install/refresh the modern CLI tools (skip clone,
                     rc-loader, oh-my-posh, zoxide). Useful when re-running
                     install.sh from an already-installed checkout.
  --tools=LIST       Install only the listed tools (comma-separated).
  --without=LIST     Install all tools EXCEPT those listed (comma-separated).
                     --tools and --without are mutually exclusive.
  --dir DIR          Install into DIR instead of the default.
  --ref REF          Check out a specific tag/branch/commit (default: latest tag).

Available tools (default: install all):
  fzf, eza, bat, fd, ripgrep, btop, ncdu, whois, dig,
  ble.sh (bash only),
  zsh-autosuggestions, zsh-syntax-highlighting (zsh only)

Environment overrides: REC_SHELL_REPO_URL, REC_SHELL_REF, REC_SHELL_DIR
EOF
}

# --- pretty output (kept visually in sync with lib/ui.sh) ------------------
# This installer runs standalone via `curl | bash`, before lib/ui.sh exists, so
# it carries its own tiny copy of the rec-shell look: minimal glyphs + color
# that honors NO_COLOR / CLICOLOR_FORCE and falls back to ASCII off a TTY.
if [ -n "${NO_COLOR+x}" ] || [ -n "${REC_NO_COLOR:-}" ]; then
  _ui_color=0
elif [ -n "${CLICOLOR_FORCE:-}" ] && [ "${CLICOLOR_FORCE}" != 0 ]; then
  _ui_color=1
elif [ -t 1 ]; then
  _ui_color=1
else
  _ui_color=0
fi
if [ "$_ui_color" = 1 ]; then
  C_B="$(printf '\033[1m')" C_G="$(printf '\033[32m')" C_Y="$(printf '\033[33m')" C_R="$(printf '\033[31m')" C_C="$(printf '\033[36m')" C_0="$(printf '\033[0m')"
else
  C_B="" C_G="" C_Y="" C_R="" C_C="" C_0=""
fi
case "${REC_UI_ASCII:-}" in
  1 | yes | true | on) _ui_utf=0 ;;
  *)
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
      *[Uu][Tt][Ff]8* | *[Uu][Tt][Ff]-8*) _ui_utf=1 ;;
      *) _ui_utf=0 ;;
    esac
    ;;
esac
if [ "$_ui_utf" = 1 ]; then
  G_OK='✓' G_WARN='⚠' G_ERR='✗' G_ARROW='➜'
else
  G_OK='[ok]' G_WARN='[!]' G_ERR='[x]' G_ARROW='->'
fi
log() { printf '%s%s%s %s\n' "$C_C" "$G_ARROW" "$C_0" "$*"; }
ok() { printf '%s%s%s %s\n' "$C_G" "$G_OK" "$C_0" "$*"; }
warn() { printf '%s%s%s %s\n' "$C_Y" "$G_WARN" "$C_0" "$*" >&2; }
err() { printf '%s%s%s %s\n' "$C_R" "$G_ERR" "$C_0" "$*" >&2; }
die() {
  err "$*"
  exit 1
}

# installer_banner VERSION [hint] -> print the rec-shell brand banner using the
# installer's local color/glyph palette. Mirrors `rec_banner` in lib/ui.sh —
# kept inline so install.sh works standalone via `curl | bash` (lib/ui.sh
# does not exist yet at this point in a fresh install).
installer_banner() {
  local _v="${1:-}" _hint="${2:-}"
  if [ "$_ui_utf" = 1 ]; then
    printf '%s   ┏━┓┏━╸┏━╸    ┏━╸╻ ╻┏━╸╻  ╻%s\n' "$C_C" "$C_0"
    printf '%s   ┣┳┛┣╸ ┃      ┗━┓┣━┫┣╸ ┃  ┃%s\n' "$C_C" "$C_0"
    printf '%s   ╹┗╸┗━╸┗━╸    ┗━┛╹ ╹┗━╸┗━╸┗━╸%s\n' "$C_C" "$C_0"
  else
    printf '%s   ___  ___  ___      ___ _  _ ___ _   _   %s\n' "$C_C" "$C_0"
    printf '%s  | _ \| __|/ __|    / __| || | __| | | |  %s\n' "$C_C" "$C_0"
    printf '%s  |   /| _|| (__     \__ \ __ | _|| |_| |_ %s\n' "$C_C" "$C_0"
    printf '%s  |_|_\|___|\___|    |___/_||_|___|___|___|%s\n' "$C_C" "$C_0"
  fi
  printf '\n'
  if [ -n "$_v" ]; then
    if [ "$_ui_color" = 1 ]; then
      printf '\033[2m   modern bash & zsh  %s  v%s\033[0m\n' "$G_ARROW" "$_v"
    else
      printf '   modern bash & zsh  %s  v%s\n' "$G_ARROW" "$_v"
    fi
  fi
  if [ -n "$_hint" ]; then
    if [ "$_ui_color" = 1 ]; then
      printf '\033[2m   %s %s\033[0m\n' "$G_ARROW" "$_hint"
    else
      printf '   %s %s\n' "$G_ARROW" "$_hint"
    fi
  fi
}

# confirm PROMPT [yes|no] -> 0/1. Reads /dev/tty so it works under `curl | bash`
# (where stdin is the pipe); returns the default when no terminal is attached.
confirm() {
  local def="${2:-no}" hint ret ans=""
  case "$def" in
    y | Y | yes | YES) hint="[Y/n]" ret=0 ;;
    *) hint="[y/N]" ret=1 ;;
  esac
  printf '%s%s%s %s %s ' "$C_C" "$G_ARROW" "$C_0" "$1" "$hint"
  read -r ans </dev/tty 2>/dev/null || ans=""
  case "$ans" in
    '') return "$ret" ;;
    y | Y | yes | YES) return 0 ;;
    *) return 1 ;;
  esac
}

# --- parse args ------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --user) MODE=user ;;
    --system) MODE=system ;;
    --unattended | -y) UNATTENDED=1 ;;
    --no-omp) INSTALL_OMP=no ;;
    --no-zoxide) INSTALL_ZOXIDE=no ;;
    --no-tools) INSTALL_TOOLS=none ;;
    --tools-only) TOOLS_ONLY=1 ;;
    --tools=*) TOOLS_ALLOW="${1#*=}" ;;
    --tools)
      shift
      TOOLS_ALLOW="${1:-}"
      ;;
    --without=*) TOOLS_DENY="${1#*=}" ;;
    --without)
      shift
      TOOLS_DENY="${1:-}"
      ;;
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

# --tools and --without are mutually exclusive.
if [ -n "$TOOLS_ALLOW" ] && [ -n "$TOOLS_DENY" ]; then
  err "--tools and --without are mutually exclusive"
  exit 2
fi

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
  curl -fsSL https://rec-shell.recwebnetwork.com/install.sh | sudo bash -s -- --system"
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

# /etc/profile.d covers login shells (bash, sh, and zsh on most distros) that
# don't source /etc/bash.bashrc from /etc/profile. Belt and suspenders for the
# rc files above: the REC_SHELL_LOADED guard makes the second sourcing a no-op.
install_profile_d_dropin() {
  [ "$MODE" = system ] || return 0
  [ -d /etc/profile.d ] || return 0
  local dropin=/etc/profile.d/rec-shell.sh
  printf '# rec-shell loader (system install)\n[ -f "%s/rec-shell.sh" ] && . "%s/rec-shell.sh"\n' \
    "$TARGET_DIR" "$TARGET_DIR" >"$dropin"
  chmod 0644 "$dropin"
  log "Wrote profile.d drop-in: $dropin"
}

ensure_omp() {
  [ "$INSTALL_OMP" = no ] && return 0
  command -v oh-my-posh >/dev/null 2>&1 && {
    log "oh-my-posh already installed"
    return 0
  }
  if [ "$UNATTENDED" -eq 0 ]; then
    if ! confirm 'Install oh-my-posh now (required for the prompt)?' no; then
      warn "Skipping oh-my-posh; the prompt will be inactive until it is installed."
      return 0
    fi
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

ensure_zoxide() {
  [ "$INSTALL_ZOXIDE" = no ] && return 0
  command -v zoxide >/dev/null 2>&1 && {
    log "zoxide already installed"
    return 0
  }
  if [ "$UNATTENDED" -eq 0 ]; then
    if ! confirm 'Install zoxide (the z smart-cd command)?' no; then
      warn "Skipping zoxide; the 'z' command will be unavailable."
      return 0
    fi
  fi
  log "Installing zoxide..."
  if [ "$OS" = mac ] && command -v brew >/dev/null 2>&1; then
    brew install zoxide
  else
    local bindir=/usr/local/bin
    [ "$(id -u)" -ne 0 ] && bindir="$HOME/.local/bin"
    mkdir -p "$bindir"
    curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh -s -- --bin-dir "$bindir" \
      || warn "zoxide install failed; install it manually: https://github.com/ajeetdsouza/zoxide"
  fi
}

# --- modern CLI tools ------------------------------------------------------
# tool_selected NAME -> 0 if this tool should be installed in the current run.
tool_selected() {
  local name="$1"
  [ "$INSTALL_TOOLS" = none ] && return 1
  # Allowlist: only members of TOOLS_ALLOW pass.
  if [ -n "$TOOLS_ALLOW" ]; then
    case ",$TOOLS_ALLOW," in
      *",$name,"*) return 0 ;;
      *) return 1 ;;
    esac
  fi
  # Denylist: members of TOOLS_DENY are skipped.
  case ",$TOOLS_DENY," in
    *",$name,"*) return 1 ;;
  esac
  return 0
}

# pm_install PKG... -> install via the first available package manager.
# Returns 1 when no PM is found or the install fails.
pm_install() {
  if command -v brew >/dev/null 2>&1; then
    brew install "$@" && return 0
  elif command -v apt-get >/dev/null 2>&1; then
    if [ "$(id -u)" -eq 0 ]; then
      apt-get update -qq && apt-get install -y "$@" && return 0
    else
      sudo -n apt-get update -qq && sudo -n apt-get install -y "$@" && return 0
    fi
  elif command -v dnf >/dev/null 2>&1; then
    if [ "$(id -u)" -eq 0 ]; then
      dnf install -y "$@" && return 0
    else
      sudo -n dnf install -y "$@" && return 0
    fi
  elif command -v pacman >/dev/null 2>&1; then
    if [ "$(id -u)" -eq 0 ]; then
      pacman -S --noconfirm "$@" && return 0
    else
      sudo -n pacman -S --noconfirm "$@" && return 0
    fi
  elif command -v apk >/dev/null 2>&1; then
    if [ "$(id -u)" -eq 0 ]; then
      apk add --no-cache "$@" && return 0
    else
      sudo -n apk add --no-cache "$@" && return 0
    fi
  fi
  return 1
}

# ensure_tool NAME CHECK_BIN PROMPT -> ask, then install via the package
# manager. CHECK_BIN is the binary name to look for on PATH. The package
# names per PM may differ (e.g. fd-find on Debian) — callers pass them as
# additional args after PROMPT.
ensure_tool() {
  local name="$1" bin="$2" prompt="$3"
  shift 3
  tool_selected "$name" || return 0
  if command -v "$bin" >/dev/null 2>&1; then
    log "$name already installed"
    return 0
  fi
  # On Debian, fd's binary is `fdfind` and bat's may be `batcat`. Accept those
  # as "already installed" so we don't try to re-install.
  case "$name" in
    fd) command -v fdfind >/dev/null 2>&1 && {
      log "$name already installed (fdfind)"
      return 0
    } ;;
    bat) command -v batcat >/dev/null 2>&1 && {
      log "$name already installed (batcat)"
      return 0
    } ;;
  esac
  if [ "$UNATTENDED" -eq 0 ]; then
    confirm "$prompt" no || {
      warn "Skipping $name."
      return 0
    }
  fi
  log "Installing $name..."
  # Try each candidate package name in turn; pm_install picks the matching PM.
  # Capture stderr to a tmp file so we can surface the actual apt/brew error
  # on final failure (e.g. "E: Unable to locate package eza" on Debian
  # without backports) instead of the previous silent ⚠.
  local pkg ok=0 errfile
  errfile="$(mktemp 2>/dev/null || mktemp -t pm_install.XXXXXX)"
  for pkg in "$@"; do
    : >"$errfile"
    if pm_install "$pkg" 2>"$errfile"; then
      ok=1
      break
    fi
  done
  if [ "$ok" -ne 1 ]; then
    warn "$name install failed; install it manually."
    if [ -s "$errfile" ]; then
      warn "Last error from the package manager:"
      sed 's/^/  /' "$errfile" >&2
    fi
    rm -f "$errfile"
    return 1
  fi
  rm -f "$errfile"
  return 0
}

# fzf has a non-standard installer (clone + run install) that is also the
# only reliable source for the shell key-bindings on minimal distros.
ensure_fzf() {
  tool_selected fzf || return 0
  command -v fzf >/dev/null 2>&1 && {
    log "fzf already installed"
    return 0
  }
  if [ "$UNATTENDED" -eq 0 ]; then
    confirm 'Install fzf (fuzzy file/dir finder)?' no || {
      warn "Skipping fzf."
      return 0
    }
  fi
  log "Installing fzf..."
  pm_install fzf 2>/dev/null && return 0
  # Fallback: clone to a local prefix.
  local prefix=/usr/local
  [ "$(id -u)" -ne 0 ] && prefix="$HOME/.fzf"
  if [ -d "$prefix/.git" ] || [ -d "$prefix/.fzf/.git" ]; then
    log "fzf checkout already exists at $prefix"
  else
    git clone --depth 1 https://github.com/junegunn/fzf.git "$prefix" 2>/dev/null \
      || {
        warn "fzf clone failed; install it manually."
        return 0
      }
  fi
  "$prefix/install" --bin --no-update-rc 2>/dev/null \
    || warn "fzf install script failed; binaries may be missing."
}

ensure_eza() { ensure_tool eza eza 'Install eza (modern ls replacement)?' eza; }
ensure_bat() { ensure_tool bat bat 'Install bat (modern cat with syntax highlighting)?' bat; }
ensure_fd() { ensure_tool fd fd 'Install fd (modern find replacement)?' fd fd-find; }
ensure_rg() { ensure_tool ripgrep rg 'Install ripgrep (fast modern grep)?' ripgrep; }
ensure_btop() { ensure_tool btop btop 'Install btop (interactive system monitor)?' btop; }
ensure_ncdu() { ensure_tool ncdu ncdu 'Install ncdu (interactive disk usage)?' ncdu; }
# `whois` is the same package name across brew/apt/dnf/pacman/apk.
ensure_whois() { ensure_tool whois whois 'Install whois (registrar / IP lookups)?' whois; }
# `dig` ships under different packages: dnsutils (apt), bind-utils (dnf/yum),
# bind (pacman / brew), bind-tools (apk). Built-in on macOS — `command -v dig`
# returns true so ensure_tool skips. On Linux, pm_install tries each candidate
# until one matches the active package manager.
ensure_dig() { ensure_tool dig dig 'Install dig (DNS lookups; used by rec dns)?' bind dnsutils bind-utils bind-tools; }

# zsh plugins live INSIDE $TARGET_DIR (so they go away with rec-shell on
# uninstall and update with `rec update` semantics). Pure shallow clones.
ensure_zsh_plugin() {
  local name="$1" repo="$2"
  tool_selected "$name" || return 0
  local dir="$TARGET_DIR/plugins/$name"
  if [ -d "$dir/.git" ]; then
    log "$name already cloned"
    return 0
  fi
  if [ "$UNATTENDED" -eq 0 ]; then
    confirm "Install $name (zsh-only enhancement)?" no || {
      warn "Skipping $name."
      return 0
    }
  fi
  log "Installing $name..."
  mkdir -p "$TARGET_DIR/plugins"
  git clone --depth 1 --quiet "$repo" "$dir" \
    || warn "$name clone failed; install it manually."
}

ensure_zsh_autosuggestions() {
  ensure_zsh_plugin zsh-autosuggestions https://github.com/zsh-users/zsh-autosuggestions.git
}
ensure_zsh_syntax_highlighting() {
  ensure_zsh_plugin zsh-syntax-highlighting https://github.com/zsh-users/zsh-syntax-highlighting.git
}

# ble.sh — the bash counterpart of zsh-autosuggestions + zsh-syntax-highlighting.
# Upstream's documented install is a recursive shallow clone followed by
# `make install PREFIX=~/.local`, which copies the prepared scripts (no
# compilation involved — make is just doing copy/templating). The end result
# lives at ~/.local/share/blesh/ble.sh, which lib/tools-catalog.sh's
# bash-plugin presence check looks for.
ensure_blesh() {
  tool_selected ble.sh || return 0
  if [ -r "$HOME/.local/share/blesh/ble.sh" ]; then
    log "ble.sh already installed"
    return 0
  fi
  if [ "$UNATTENDED" -eq 0 ]; then
    confirm 'Install ble.sh (bash autosuggestions + syntax highlighting)?' no || {
      warn "Skipping ble.sh."
      return 0
    }
  fi
  log "Installing ble.sh..."
  if ! command -v make >/dev/null 2>&1; then
    warn "ble.sh install needs 'make' (apt install make / brew install make)."
    return 1
  fi
  if ! command -v git >/dev/null 2>&1; then
    warn "ble.sh install needs 'git'."
    return 1
  fi
  local tmpdir
  tmpdir="$(mktemp -d)"
  if git clone --recursive --depth 1 --shallow-submodules \
    https://github.com/akinomyoga/ble.sh.git "$tmpdir/ble.sh" 2>"$tmpdir/clone.err" \
    && make -C "$tmpdir/ble.sh" install PREFIX="$HOME/.local" >"$tmpdir/make.log" 2>&1; then
    rm -rf "$tmpdir"
    return 0
  fi
  warn "ble.sh install failed."
  [ -s "$tmpdir/clone.err" ] && sed 's/^/  /' "$tmpdir/clone.err" >&2
  [ -s "$tmpdir/make.log" ] && tail -n 20 "$tmpdir/make.log" | sed 's/^/  /' >&2
  rm -rf "$tmpdir"
  return 1
}

install_tools_all() {
  [ "$INSTALL_TOOLS" = none ] && {
    log "Skipping all CLI tools (--no-tools)"
    return 0
  }
  ensure_fzf
  ensure_eza
  ensure_bat
  ensure_fd
  ensure_rg
  ensure_btop
  ensure_ncdu
  ensure_whois
  ensure_dig
  ensure_zsh_autosuggestions
  ensure_zsh_syntax_highlighting
  ensure_blesh
}

# --- run -------------------------------------------------------------------
if [ "$TOOLS_ONLY" -eq 1 ]; then
  log "Installing/refreshing CLI tools only (--tools-only)"
  TARGET_DIR="${REC_SHELL_DIR:-$TARGET_DIR}"
  install_tools_all
  ok "tools install complete."
  exit 0
fi

log "Installing rec-shell (${C_B}${MODE}${C_0}) into ${C_B}${TARGET_DIR}${C_0}"
ensure_git
clone_or_update
install_loader_lines
install_profile_d_dropin
ensure_omp
ensure_zoxide
install_tools_all

# Pick the rc file the user's *current* shell will pick up on a fresh start.
# Falls back to bash when $SHELL is unset (e.g. minimal cloud images).
post_install_rc_hint() {
  local shell_bin="${SHELL:-/bin/bash}"
  local shell_name="${shell_bin##*/}"
  case "$shell_name" in
    zsh) [ "$MODE" = system ] && system_rc_for zsh || printf '%s/.zshrc' "$HOME" ;;
    bash) [ "$MODE" = system ] && system_rc_for bash || printf '%s/.bashrc' "$HOME" ;;
    *) [ "$MODE" = system ] && system_rc_for bash || printf '%s/.bashrc' "$HOME" ;;
  esac
}

VER="$(head -n1 "$TARGET_DIR/VERSION" 2>/dev/null || echo '?')"
RC_HINT="$(post_install_rc_hint)"
SHELL_BIN="${SHELL:-/bin/bash}"

printf '\n'
ok "rec-shell $VER installed."
printf '\n'
installer_banner "$VER" "rec doctor"
printf '\n'
printf '%sTo use rec-shell now%s in your current shell, run one of:\n' "$C_B" "$C_0"
printf '  %ssource %s%s   %s# loads rec into this shell%s\n' "$C_C" "$RC_HINT" "$C_0" "$C_Y" "$C_0"
printf '  %sexec %s -l%s        %s# starts a fresh login shell (recommended)%s\n' "$C_C" "$SHELL_BIN" "$C_0" "$C_Y" "$C_0"
printf '\n'
if [ "$MODE" = system ]; then
  INSTALL_CMD='sudo bash -s -- --system'
else
  INSTALL_CMD='bash'
fi
printf '%sTip%s: chain %s&& exec %s -l%s next time so the new shell has it ready:\n' "$C_B" "$C_0" "$C_C" "$SHELL_BIN" "$C_0"
printf '  %scurl -fsSL https://rec-shell.recwebnetwork.com/install.sh | %s && exec %s -l%s\n' \
  "$C_C" "$INSTALL_CMD" "$SHELL_BIN" "$C_0"
printf '\n'
printf 'New shells started after this point will have %srec%s available automatically.\n' "$C_B" "$C_0"
printf 'Then check it with: %srec doctor%s\n' "$C_B" "$C_0"
