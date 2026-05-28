#!/usr/bin/env bash
#
# rec-shell installer.
#
#   curl -fsSL https://rec-shell.recwebnetwork.com/install.sh | bash && exec $SHELL -l
#   curl -fsSL https://rec-shell.recwebnetwork.com/install.sh | sudo bash -s -- --system && exec $SHELL -l
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
    --user) MODE=user; MODE_EXPLICIT=1 ;;
    --system) MODE=system; MODE_EXPLICIT=1 ;;
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

# --- platform detection: OS + DISTRO + package manager -------------------
# detect_platform sets OS, DISTRO, PM in one place. Idempotent — tests pin
# the inputs via REC_TEST_UNAME / REC_OS_RELEASE_FILE so they don't depend
# on the host's actual distro.
detect_platform() {
  local _u _osrel
  _u="${REC_TEST_UNAME:-$(uname -s)}"
  _osrel="${REC_OS_RELEASE_FILE:-/etc/os-release}"
  case "$_u" in
    Darwin) OS=mac; DISTRO=mac; PM=brew ;;
    Linux)
      OS=linux; DISTRO=unknown; PM=unknown
      if [ -r "$_osrel" ]; then
        # shellcheck disable=SC1090
        ( . "$_osrel" 2>/dev/null; printf 'ID=%s\nID_LIKE=%s\n' "${ID-}" "${ID_LIKE-}" ) >"${TMPDIR:-/tmp}/.rec-os-id.$$"
        # shellcheck disable=SC1091
        . "${TMPDIR:-/tmp}/.rec-os-id.$$" 2>/dev/null || true
        rm -f "${TMPDIR:-/tmp}/.rec-os-id.$$"
      fi
      case "${ID:-}:${ID_LIKE:-}" in
        ubuntu*|debian*|*:*ubuntu*|*:*debian*|pop*|linuxmint*|*:*mint*) DISTRO="${ID:-debian}"; PM=apt ;;
        fedora*|rhel*|centos*|rocky*|almalinux*|*:*fedora*|*:*rhel*) DISTRO="${ID:-fedora}"; PM=dnf ;;
        arch*|manjaro*|endeavouros*|*:*arch*) DISTRO="${ID:-arch}"; PM=pacman ;;
        alpine*|*:*alpine*) DISTRO=alpine; PM=apk ;;
        opensuse*|suse*|*:*suse*) DISTRO="${ID:-opensuse}"; PM=zypper ;;
      esac
      ;;
    *) die "unsupported OS: $_u" ;;
  esac
  unset ID ID_LIKE
  return 0
}
detect_platform

# prompt_install_mode reads /dev/tty so it works under `curl|bash` too.
# Skipped when an existing checkout is detected (auto-upgrade) or when
# --user/--system was passed explicitly.
prompt_install_mode() {
  [ -n "${MODE_EXPLICIT:-}" ] && return 0
  if [ -d "$HOME/.rec-shell/.git" ]; then MODE=user; return 0; fi
  if [ -d /opt/rec-shell/.git ]; then MODE=system; return 0; fi
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf '%sInstall where? [u]ser (~/.rec-shell, no sudo) or [s]ystem (/opt/rec-shell, sudo)? [u]: %s' \
      "$C_B" "$C_0" >/dev/tty
    IFS= read -r _mode </dev/tty || _mode=u
    case "${_mode:-u}" in
      s|S|system) MODE=system ;;
      *)          MODE=user ;;
    esac
    unset _mode
  else
    MODE=user
  fi
}

# --- quiet needrestart (Ubuntu) --------------------------------------------
# Ubuntu auto-runs `needrestart` after every apt-get install, dumping 5+
# lines per tool ("Running kernel seems to be up-to-date" / "No services
# need to be restarted" / …). MODE=l + SUSPEND=1 makes it list-only and
# bypassable, suppressing the post-install chatter without disabling the
# tool itself. Ignored on Debian-without-needrestart and macOS.
export NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1

# --- detect invoking user's shell ------------------------------------------
# Under `sudo bash`, $SHELL is unreliable (env_reset strips it; on macOS it
# often ends up /bin/sh from root's defaults). $SUDO_USER + the system's
# passwd lookup resolves to the *invoking* user's login shell — Linux uses
# `getent passwd`, macOS doesn't ship getent so we fall through to
# `dscl . -read`. Final fallback to $SHELL covers non-sudo runs. Unknown
# shells (e.g. /bin/sh) collapse to /bin/bash so the post-install hint
# always recommends a real interactive shell. Tests can pin USER_SHELL /
# USER_SHELL_PATH directly via env.
detect_user_shell_path() {
  local sh=""
  if [ -n "${SUDO_USER:-}" ]; then
    if [ -z "$sh" ] && command -v getent >/dev/null 2>&1; then
      sh="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f7)"
    fi
    if [ -z "$sh" ] && command -v dscl >/dev/null 2>&1; then
      sh="$(dscl . -read "/Users/$SUDO_USER" UserShell 2>/dev/null | awk '/UserShell:/ { print $2 }')"
    fi
  fi
  [ -z "$sh" ] && sh="${SHELL:-/bin/bash}"
  case "${sh##*/}" in
    zsh | bash) printf '%s\n' "$sh" ;;
    *) printf '/bin/bash\n' ;;
  esac
}
detect_user_shell() {
  local p
  p="$(detect_user_shell_path)"
  printf '%s\n' "${p##*/}"
}
USER_SHELL_PATH="${USER_SHELL_PATH:-$(detect_user_shell_path)}"
USER_SHELL="${USER_SHELL:-${USER_SHELL_PATH##*/}}"

# --- target dir + privileges ----------------------------------------------
if [ "$MODE" = system ]; then
  TARGET_DIR="${TARGET_DIR:-/opt/rec-shell}"
  if [ "$(id -u)" -ne 0 ]; then
    die "System install must run as root:
  curl -fsSL https://rec-shell.recwebnetwork.com/install.sh | sudo bash -s -- --system && exec \$SHELL -l"
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
  if [ -f "$rc" ] && grep -qF "$dir/rec-shell.sh\"" "$rc"; then
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

# Prepend a no-op `bleopt` stub at the TOP of bash rc files. oh-my-posh's
# `init bash` output (often eval'd from /etc/bash.bashrc BEFORE our
# loader's append-at-bottom runs) contains `bleopt prompt_ps1_transient=…`
# and `bleopt prompt_ps1_final=…` calls that assume ble.sh is already
# loaded. Without ble.sh those calls print "bash: bleopt: command not
# found" at every interactive shell start. The stub silently absorbs them
# until rec-shell loads ble.sh and overrides bleopt with the real function.
# bash-only: zsh users don't run ble.sh and oh-my-posh's zsh init doesn't
# emit bleopt calls.
ensure_bleopt_prestub_in_rc() {
  local rc="$1"
  if [ -f "$rc" ] && grep -qF '# rec-shell (pre-stub)' "$rc"; then
    return 0
  fi
  mkdir -p "$(dirname "$rc")"
  backup_once "$rc"
  local tmp
  tmp="$(mktemp "$rc.rec.XXXXXX" 2>/dev/null)" || tmp="$(mktemp -t rec-pre.XXXXXX)"
  {
    printf '# rec-shell (pre-stub)\nbleopt() { :; }\n'
    [ -f "$rc" ] && cat "$rc"
  } >"$tmp"
  mv "$tmp" "$rc"
  log "Prepended bleopt pre-stub to $rc"
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
    # Bash rc files also need the bleopt no-op at the top (see comment on
    # ensure_bleopt_prestub_in_rc) to absorb oh-my-posh's pre-loader calls.
    [ "$s" = bash ] && [ -n "$rc" ] && ensure_bleopt_prestub_in_rc "$rc"
  done
  # User-mode bash: login shells source ~/.bash_profile / ~/.bash_login /
  # ~/.profile (first one that exists) and may or may not chain on to
  # ~/.bashrc. To guarantee `rec` works after `exec $SHELL -l`, also
  # write the loader to whichever login-shell rc file exists. The
  # REC_SHELL_LOADED guard in rec-shell.sh makes the second sourcing a
  # no-op when both files are read.
  if [ "$MODE" != system ] && command -v bash >/dev/null 2>&1; then
    for rc in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
      [ -f "$rc" ] && ensure_loader_in_rc "$rc" && break
    done
  fi
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
    # oh-my-posh's official installer needs unzip; pre-install it so the
    # pipe doesn't bail with "unzip is required to install Oh My Posh."
    if ! command -v unzip >/dev/null 2>&1; then
      log "oh-my-posh needs unzip; installing..."
      if ! pm_install unzip; then
        warn "oh-my-posh requires unzip (apt install unzip / dnf install unzip)."
        return 1
      fi
    fi
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
#
# Shell-plugin filtering follows the invoking user's shell (USER_SHELL), in
# both --user and --system mode. This avoids prompting a bash user for zsh
# plugins (or vice versa) just because their host happens to default to a
# different shell. ble.sh keeps a hard exclusion on macOS because its make
# build needs gawk, which BSD awk on macOS isn't.
tool_selected() {
  local name="$1"
  case "$INSTALL_TOOLS" in
    none | done) return 1 ;;
  esac
  # Allowlist wins: when the user names a tool explicitly (--tools=NAME or
  # `rec install NAME`), honor that and skip the shell/OS prompt filter —
  # they opted in.
  if [ -n "$TOOLS_ALLOW" ]; then
    case ",$TOOLS_ALLOW," in
      *",$name,"*) return 0 ;;
      *) return 1 ;;
    esac
  fi
  # No allowlist: hide shell plugins that don't fit the invoking user's
  # shell so we don't prompt for things they can't realistically use.
  case "$name" in
    ble.sh)
      [ "$USER_SHELL" = bash ] || return 1
      [ "$OS" = mac ] && return 1
      ;;
    zsh-autosuggestions | zsh-syntax-highlighting)
      [ "$USER_SHELL" = zsh ] || return 1
      ;;
  esac
  # Denylist: members of TOOLS_DENY are skipped.
  case ",$TOOLS_DENY," in
    *",$name,"*) return 1 ;;
  esac
  return 0
}

# pm_install PKG... -> install via the first available package manager.
# Returns 1 when no PM is found, the install fails, or (in user mode on
# Linux) sudo refuses non-interactive auth — without trying sudo more
# than once, so we don't dump "sudo: interactive authentication is
# required" mid-install. Callers are expected to surface an actionable
# message in that case (see ensure_blesh's dep loop).
pm_install() {
  if command -v brew >/dev/null 2>&1; then
    brew install "$@" && return 0
    return 1
  fi
  # Linux PMs: same shape — root runs the tool directly; otherwise check
  # once if `sudo -n` works (passwordless sudo configured), bail fast if
  # not, and only THEN run the install via sudo. Avoids the multi-line
  # "interactive authentication is required" noise in user installs.
  local _pmi_sudo=""
  if [ "$(id -u)" -ne 0 ]; then
    if sudo -n true 2>/dev/null; then
      _pmi_sudo="sudo -n"
    else
      return 1
    fi
  fi
  if command -v apt-get >/dev/null 2>&1; then
    $_pmi_sudo apt-get update -qq && $_pmi_sudo apt-get install -y "$@" && return 0
  elif command -v dnf >/dev/null 2>&1; then
    $_pmi_sudo dnf install -y "$@" && return 0
  elif command -v pacman >/dev/null 2>&1; then
    $_pmi_sudo pacman -S --noconfirm "$@" && return 0
  elif command -v apk >/dev/null 2>&1; then
    $_pmi_sudo apk add --no-cache "$@" && return 0
  fi
  return 1
}

# __rec_default_term -> give TERM a sensible default if the env stripped it.
# `sudo` with default sudoers (env_reset) removes TERM, which makes the
# multiselect picker bail (__rec_ui_interactive rejects empty TERM). Real
# terminals under sudo still render ANSI just fine, so we plug a modern
# default back in.
__rec_default_term() {
  [ -z "${TERM:-}" ] && export TERM=xterm-256color
  return 0
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

# eza is NOT in Debian < 12, in older Ubuntu LTS, or in CentOS 7. When apt /
# dnf / brew can't deliver it, fall back to the prebuilt binary from upstream
# GitHub releases — cross-distro, no extra repos to add. On macOS without brew
# the fallback path doesn't apply (eza upstream doesn't ship Darwin binaries),
# so we surface a clear message.
ensure_eza() {
  tool_selected eza || return 0
  if command -v eza >/dev/null 2>&1; then
    log "eza already installed"
    return 0
  fi
  if [ "$UNATTENDED" -eq 0 ]; then
    confirm 'Install eza (modern ls replacement)?' no || {
      warn "Skipping eza."
      return 0
    }
  fi
  log "Installing eza..."
  # Fast path: package manager.
  local _eza_err
  _eza_err="$(mktemp 2>/dev/null || mktemp -t pm_install.XXXXXX)"
  if pm_install eza 2>"$_eza_err"; then
    rm -f "$_eza_err"
    return 0
  fi
  # Fallback path: prebuilt binary from upstream releases. Only Linux has
  # binaries; macOS users without brew need brew or `cargo install eza`.
  case "$(uname -s)" in
    Linux) ;;
    Darwin)
      warn "eza install failed. Install Homebrew (https://brew.sh) and retry, or run: cargo install eza"
      [ -s "$_eza_err" ] && sed 's/^/  /' "$_eza_err" >&2
      rm -f "$_eza_err"
      return 1
      ;;
    *)
      warn "eza install failed on $(uname -s); install it manually."
      rm -f "$_eza_err"
      return 1
      ;;
  esac
  local _eza_arch _eza_suffix
  _eza_arch="$(uname -m)"
  case "$_eza_arch" in
    x86_64 | amd64) _eza_suffix="x86_64-unknown-linux-musl" ;;
    aarch64 | arm64) _eza_suffix="aarch64-unknown-linux-gnu" ;;
    armv7* | armhf) _eza_suffix="arm-unknown-linux-gnueabihf" ;;
    *)
      warn "eza: no prebuilt binary for arch '$_eza_arch'; install it manually (e.g. cargo install eza)."
      rm -f "$_eza_err"
      return 1
      ;;
  esac
  if ! command -v curl >/dev/null 2>&1; then
    warn "eza fallback needs 'curl'."
    rm -f "$_eza_err"
    return 1
  fi
  if ! command -v tar >/dev/null 2>&1; then
    warn "eza fallback needs 'tar'."
    rm -f "$_eza_err"
    return 1
  fi
  local _eza_bindir=/usr/local/bin
  [ "$(id -u)" -ne 0 ] && _eza_bindir="$HOME/.local/bin"
  mkdir -p "$_eza_bindir"
  local _eza_tmp _eza_url
  _eza_tmp="$(mktemp -d)"
  _eza_url="https://github.com/eza-community/eza/releases/latest/download/eza_${_eza_suffix}.tar.gz"
  log "Package manager couldn't install eza; downloading prebuilt binary ($_eza_arch) from GitHub..."
  if curl -fsSL "$_eza_url" -o "$_eza_tmp/eza.tar.gz" \
    && tar -xzf "$_eza_tmp/eza.tar.gz" -C "$_eza_tmp" \
    && [ -x "$_eza_tmp/eza" ] \
    && mv "$_eza_tmp/eza" "$_eza_bindir/eza"; then
    chmod +x "$_eza_bindir/eza"
    log "eza installed to $_eza_bindir/eza"
    rm -rf "$_eza_tmp" "$_eza_err"
    return 0
  fi
  warn "eza install failed (package manager + GitHub fallback both errored)."
  [ -s "$_eza_err" ] && {
    warn "Package manager error:"
    sed 's/^/  /' "$_eza_err" >&2
  }
  rm -rf "$_eza_tmp" "$_eza_err"
  return 1
}
ensure_bat() { ensure_tool bat bat 'Install bat (modern cat with syntax highlighting)?' bat; }
ensure_fd() { ensure_tool fd fd 'Install fd (modern find replacement)?' fd fd-find; }
ensure_rg() { ensure_tool ripgrep rg 'Install ripgrep (fast modern grep)?' ripgrep; }
# btop isn't in Debian < 12, in older Ubuntu LTS, or in CentOS 7. Same
# fallback pattern as ensure_eza: try the package manager first; on Linux,
# fall back to upstream's prebuilt static binary from GitHub releases. The
# btop release tarball is .tbz (bzip2) with a `btop/bin/btop` layout plus a
# `themes/` directory we copy alongside it when present.
ensure_btop() {
  tool_selected btop || return 0
  if command -v btop >/dev/null 2>&1; then
    log "btop already installed"
    return 0
  fi
  if [ "$UNATTENDED" -eq 0 ]; then
    confirm 'Install btop (interactive system monitor)?' no || {
      warn "Skipping btop."
      return 0
    }
  fi
  log "Installing btop..."
  local _btop_err
  _btop_err="$(mktemp 2>/dev/null || mktemp -t pm_install.XXXXXX)"
  if pm_install btop 2>"$_btop_err"; then
    rm -f "$_btop_err"
    return 0
  fi
  case "$(uname -s)" in
    Linux) ;;
    Darwin)
      warn "btop install failed. Install Homebrew (https://brew.sh) and retry, or build from source."
      [ -s "$_btop_err" ] && sed 's/^/  /' "$_btop_err" >&2
      rm -f "$_btop_err"
      return 1
      ;;
    *)
      warn "btop install failed on $(uname -s); install it manually."
      rm -f "$_btop_err"
      return 1
      ;;
  esac
  # Asset naming on btop releases follows Rust target-triple convention with
  # an `-unknown-` segment, and the archive is .tar.gz (older releases used
  # .tbz). Verified against the GitHub releases API at the time of writing.
  local _btop_arch _btop_suffix
  _btop_arch="$(uname -m)"
  case "$_btop_arch" in
    x86_64 | amd64) _btop_suffix="x86_64-unknown-linux-musl" ;;
    aarch64 | arm64) _btop_suffix="aarch64-unknown-linux-musl" ;;
    armv7* | armhf) _btop_suffix="armv7-unknown-linux-musleabi" ;;
    armv6*) _btop_suffix="arm-unknown-linux-musleabi" ;;
    *)
      warn "btop: no prebuilt binary for arch '$_btop_arch'; install it manually."
      rm -f "$_btop_err"
      return 1
      ;;
  esac
  if ! command -v curl >/dev/null 2>&1; then
    warn "btop fallback needs 'curl'."
    rm -f "$_btop_err"
    return 1
  fi
  if ! command -v tar >/dev/null 2>&1; then
    warn "btop fallback needs 'tar'."
    rm -f "$_btop_err"
    return 1
  fi
  local _btop_bindir _btop_sharedir
  if [ "$(id -u)" -eq 0 ]; then
    _btop_bindir=/usr/local/bin
    _btop_sharedir=/usr/local/share/btop
  else
    _btop_bindir="$HOME/.local/bin"
    _btop_sharedir="$HOME/.config/btop"
  fi
  mkdir -p "$_btop_bindir" "$_btop_sharedir"
  local _btop_tmp _btop_url
  _btop_tmp="$(mktemp -d)"
  _btop_url="https://github.com/aristocratos/btop/releases/latest/download/btop-${_btop_suffix}.tar.gz"
  log "Package manager couldn't install btop; downloading prebuilt binary ($_btop_arch) from GitHub..."
  if curl -fsSL "$_btop_url" -o "$_btop_tmp/btop.tar.gz" \
    && tar -xzf "$_btop_tmp/btop.tar.gz" -C "$_btop_tmp" \
    && [ -x "$_btop_tmp/btop/bin/btop" ] \
    && mv "$_btop_tmp/btop/bin/btop" "$_btop_bindir/btop"; then
    chmod +x "$_btop_bindir/btop"
    # Themes are nice-to-have; ignore errors if the share dir isn't writable.
    if [ -d "$_btop_tmp/btop/themes" ]; then
      cp -r "$_btop_tmp/btop/themes" "$_btop_sharedir/" 2>/dev/null || :
    fi
    log "btop installed to $_btop_bindir/btop"
    rm -rf "$_btop_tmp" "$_btop_err"
    return 0
  fi
  warn "btop install failed (package manager + GitHub fallback both errored)."
  [ -s "$_btop_err" ] && {
    warn "Package manager error:"
    sed 's/^/  /' "$_btop_err" >&2
  }
  rm -rf "$_btop_tmp" "$_btop_err"
  return 1
}
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
  # ble.sh's build chain needs make + git + gawk. (gawk specifically —
  # BSD awk on macOS and mawk on some Debian variants are rejected by
  # GNUmakefile:29 with "Sorry, gawk could not be found".) The user
  # explicitly opted in to ble.sh, so opt them in to its build deps too:
  # try pm_install for each missing one; only fall through to the
  # actionable warning when the package manager itself fails.
  local _bdep
  for _bdep in make git gawk; do
    if ! command -v "$_bdep" >/dev/null 2>&1; then
      log "ble.sh needs $_bdep; installing..."
      if ! pm_install "$_bdep"; then
        warn "ble.sh requires $_bdep (and the others: make, git, gawk)."
        if [ "$OS" = mac ]; then
          warn "  brew install make git gawk"
        else
          warn "  apt install make git gawk    # Debian/Ubuntu"
          warn "  dnf install make git gawk    # Fedora/RHEL"
        fi
        return 1
      fi
    fi
  done
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

# install_build_deps -> collect every binary the bundled tools need, install
# the missing ones in ONE pm_install call (one apt-get transaction, one
# spinner, one log file). Replaces the per-tool dep loops scattered across
# ensure_omp/ensure_blesh/ensure_eza/ensure_btop. Runs once, early in the
# bootstrap, before any per-tool installer touches PATH.
install_build_deps() {
  local _ibd_needed="" _ibd_dep
  # Why each:
  #   curl, git  → infrastructure (clones, downloads)
  #   unzip, zip → oh-my-posh's official installer needs unzip; some
  #                themes ship .zip archives that need zip too
  #   make, gawk → ble.sh's build chain (Makefile + GNU awk)
  #   tar        → eza/btop GitHub-release fallback unpacks .tar.gz
  for _ibd_dep in curl git unzip zip make gawk tar; do
    command -v "$_ibd_dep" >/dev/null 2>&1 || _ibd_needed="$_ibd_needed $_ibd_dep"
  done
  if [ -z "$_ibd_needed" ]; then
    return 0
  fi
  # shellcheck disable=SC2086 # intentional word-split: pm_install wants
  # each dep as a separate positional arg.
  pm_install $_ibd_needed
}

# __rec_install_quietly LABEL TOOL CMD [ARG...] -> run CMD with a spinner
# (if rec_ui_spin is loaded) and capture stdout+stderr to a per-tool log
# at $REC_CACHE_DIR/install-logs/<tool>.log. Falls back to a step+log line
# when the spinner isn't available. On failure tails the last 10 log
# lines to stderr for actionable context.
__rec_install_quietly() {
  local _riq_label="$1" _riq_tool="$2"
  shift 2
  local _riq_logdir _riq_logfile _riq_rc
  _riq_logdir="${REC_CACHE_DIR:-${HOME}/.cache/rec-shell}/install-logs"
  command mkdir -p "$_riq_logdir" 2>/dev/null || true
  _riq_logfile="$_riq_logdir/$_riq_tool.log"
  # rec_ui_spin lives in lib/ui-interactive.sh and emits its final ✓/✗
  # via rec_ui_ok / rec_ui_err from lib/ui.sh. install.sh is normally
  # standalone, but after clone_or_update both libs are on disk — try
  # to source them on demand (ui.sh first because ui-interactive.sh
  # depends on it). If anything's missing the fallback path still works.
  if ! command -v rec_ui_spin >/dev/null 2>&1; then
    [ -r "$TARGET_DIR/lib/ui.sh" ] \
      && . "$TARGET_DIR/lib/ui.sh" 2>/dev/null || true
    [ -r "$TARGET_DIR/lib/ui-interactive.sh" ] \
      && . "$TARGET_DIR/lib/ui-interactive.sh" 2>/dev/null || true
  fi
  # Inner closure: redirects the wrapped command's stdout+stderr to the
  # log file. rec_ui_spin's own >/dev/null wrap is a no-op once this
  # closure has already moved everything to the file.
  __rec_iqr() { "$@" >"$_riq_logfile" 2>&1; }
  if command -v rec_ui_spin >/dev/null 2>&1; then
    if rec_ui_spin "$_riq_label" __rec_iqr "$@"; then _riq_rc=0; else _riq_rc=$?; fi
  else
    log "$_riq_label"
    if "$@" >"$_riq_logfile" 2>&1; then _riq_rc=0; else _riq_rc=$?; fi
    [ "$_riq_rc" -eq 0 ] && ok "$_riq_tool" || warn "$_riq_tool failed"
  fi
  if [ "$_riq_rc" -ne 0 ]; then
    warn "log: $_riq_logfile"
    tail -n 10 "$_riq_logfile" 2>/dev/null | sed 's/^/  /' >&2 || true
  fi
  return "$_riq_rc"
}

# ensure_one_tool NAME -> dispatch by tool name to the matching per-tool
# installer. Replaces the 12-line static dispatch in the old
# install_tools_all so install_all_tools can walk the catalog generically.
ensure_one_tool() {
  case "$1" in
    fzf)                       ensure_fzf ;;
    eza)                       ensure_eza ;;
    bat)                       ensure_bat ;;
    fd)                        ensure_fd ;;
    ripgrep)                   ensure_rg ;;
    btop)                      ensure_btop ;;
    ncdu)                      ensure_ncdu ;;
    whois)                     ensure_whois ;;
    dig)                       ensure_dig ;;
    zsh-autosuggestions)       ensure_zsh_autosuggestions ;;
    zsh-syntax-highlighting)   ensure_zsh_syntax_highlighting ;;
    ble.sh)                    ensure_blesh ;;
    *) warn "unknown tool: $1"; return 1 ;;
  esac
}

# install_all_tools -> walk the catalog of MISSING tools and install each
# under the quiet spinner, with a (i/N) counter in the label so the user
# sees overall progress. No picker, no y/N — that's the whole point of
# v2.0.0. Honors --no-tools (the only opt-out).
install_all_tools() {
  case "$INSTALL_TOOLS" in
    none) log "Skipping all CLI tools (--no-tools)"; return 0 ;;
    done) return 0 ;;
  esac
  # Source lib/tools-catalog.sh (+ core.sh which it depends on) so we can
  # ask which tools are missing. clone_or_update has run by now. Skip the
  # source if rec_tools_missing is already defined — tests pre-stub it.
  REC_SHELL_NAME="$USER_SHELL"
  REC_SHELL_DIR="$TARGET_DIR"
  export REC_SHELL_NAME REC_SHELL_DIR
  if ! command -v rec_tools_missing >/dev/null 2>&1; then
    if [ -r "$TARGET_DIR/lib/core.sh" ]; then
      # shellcheck disable=SC1091
      . "$TARGET_DIR/lib/core.sh" 2>/dev/null || true
    fi
    if [ -r "$TARGET_DIR/lib/tools-catalog.sh" ]; then
      # shellcheck disable=SC1091
      . "$TARGET_DIR/lib/tools-catalog.sh" 2>/dev/null || true
    fi
  fi
  local _missing _total _i=0 _ok=0 _fail=0 _tool
  if [ -n "${TOOLS_ALLOW:-}" ]; then
    # User pinned a tool set via --tools=a,b,c — walk that list directly.
    _missing="$(printf '%s' "$TOOLS_ALLOW" | tr ',' '\n' | awk 'NF')"
  elif command -v rec_tools_missing >/dev/null 2>&1; then
    _missing="$(rec_tools_missing | awk 'NF')"
  else
    warn "tools-catalog unavailable; skipping bundled tool installs"
    return 0
  fi
  if [ -z "$_missing" ]; then
    log "CLI tools: all already installed"
    return 0
  fi
  _total=$(printf '%s\n' "$_missing" | wc -l | tr -d ' ')
  while IFS= read -r _tool; do
    [ -z "$_tool" ] && continue
    _i=$((_i + 1))
    if __rec_install_quietly "CLI tools ($_i/$_total) $_tool" "$_tool" ensure_one_tool "$_tool"; then
      _ok=$((_ok + 1))
    else
      _fail=$((_fail + 1))
    fi
  done <<EOF
$_missing
EOF
  if [ "$_fail" -eq 0 ]; then
    ok "CLI tools: $_ok installed"
  else
    warn "CLI tools: $_ok installed, $_fail failed (logs in ${REC_CACHE_DIR:-$HOME/.cache/rec-shell}/install-logs/)"
  fi
}

# --- run -------------------------------------------------------------------
# Bats tests source this file to exercise its functions without executing the
# installer; setting REC_INSTALL_SOURCED=1 before sourcing skips the run block
# below. The default (unset) preserves normal `curl | bash` behavior.
if [ "${REC_INSTALL_SOURCED:-0}" -ne 1 ]; then

if [ "$TOOLS_ONLY" -eq 1 ]; then
  log "Installing/refreshing CLI tools only (--tools-only)"
  TARGET_DIR="${REC_SHELL_DIR:-$TARGET_DIR}"
  install_all_tools
  ok "tools install complete."
  exit 0
fi

prompt_install_mode
# Re-resolve TARGET_DIR now that MODE may have been chosen via the prompt
# (the early system/user dispatch ran before prompt_install_mode).
if [ "$MODE" = system ]; then
  TARGET_DIR="${TARGET_DIR:-/opt/rec-shell}"
else
  TARGET_DIR="${TARGET_DIR:-$HOME/.rec-shell}"
fi

log "Installing rec-shell (${C_B}${MODE}${C_0}) into ${C_B}${TARGET_DIR}${C_0}"
ensure_git
clone_or_update
install_loader_lines
install_profile_d_dropin
install_build_deps
__rec_install_quietly "oh-my-posh" oh-my-posh ensure_omp
__rec_install_quietly "zoxide"     zoxide     ensure_zoxide
install_all_tools

# Pick the rc file the user's *current* shell will pick up on a fresh
# start. Keys off USER_SHELL (the invoking user's actual shell) rather
# than raw $SHELL — under `sudo` that one's been stripped to /bin/sh on
# macOS and would otherwise point users at the wrong rc file.
post_install_rc_hint() {
  case "$USER_SHELL" in
    zsh) [ "$MODE" = system ] && system_rc_for zsh || printf '%s/.zshrc' "$HOME" ;;
    *) [ "$MODE" = system ] && system_rc_for bash || printf '%s/.bashrc' "$HOME" ;;
  esac
}

VER="$(head -n1 "$TARGET_DIR/VERSION" 2>/dev/null || echo '?')"
RC_HINT="$(post_install_rc_hint)"
SHELL_BIN="$USER_SHELL_PATH"

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

fi # REC_INSTALL_SOURCED guard
