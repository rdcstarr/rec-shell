#!/bin/sh
# shellcheck shell=sh
#
# rec-shell uninstaller. Removes the loader line from rc files and deletes the
# install directory. Keeps your config/cache unless --purge is given.
#
#   rec-shell uninstall          # remove, keep config
#   rec-shell uninstall --purge  # remove everything

set -eu

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1
MARKER="# rec-shell"
# Prefix match — catches the loader line ("# rec-shell") AND any rec-shell
# pre-stub block we prepend (e.g. "# rec-shell (pre-stub)"). Each block is
# 2 lines: marker comment + the actual line.
MARKER_PREFIX="# rec-shell"

# --- pretty output (kept in sync with lib/ui.sh) ---------------------------
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
  C_G="$(printf '\033[32m')" C_Y="$(printf '\033[33m')" C_C="$(printf '\033[36m')" C_0="$(printf '\033[0m')"
else
  C_G="" C_Y="" C_C="" C_0=""
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
  G_OK='✓' G_INFO='ℹ' G_WARN='⚠'
else
  G_OK='[ok]' G_INFO='[i]' G_WARN='[!]'
fi
ok() { printf '%s%s%s %s\n' "$C_G" "$G_OK" "$C_0" "$*"; }
info() { printf '%s%s%s %s\n' "$C_C" "$G_INFO" "$C_0" "$*"; }
skip() { printf '%s%s%s %s\n' "$C_Y" "$G_WARN" "$C_0" "$*" >&2; }

# Remove the marker line and the loader line that follows it (anchored on the
# marker comment, so it works even if the path changed).
strip_rc() {
  rc="$1"
  [ -f "$rc" ] || return 0
  grep -qF "$MARKER_PREFIX" "$rc" 2>/dev/null || return 0
  if [ ! -w "$rc" ]; then
    skip "no write permission: $rc"
    return 0
  fi
  tmp="$rc.rec-uninstall.$$"
  # Match every line that STARTS with "# rec-shell" and drop it + the
  # following line. Catches the loader block AND the bash pre-stub block.
  awk -v p="$MARKER_PREFIX" 'index($0, p) == 1 { drop = 2 } drop > 0 { drop--; next } { print }' "$rc" >"$tmp" \
    && mv "$tmp" "$rc" \
    && ok "removed rec-shell lines from $rc"
}

for rc in "$HOME/.zshrc" "$HOME/.bashrc" /etc/zshrc /etc/zsh/zshrc /etc/bash.bashrc /etc/bashrc; do
  strip_rc "$rc"
done

# Drop the profile.d shim written by --system installs.
if [ -f /etc/profile.d/rec-shell.sh ]; then
  if [ -w /etc/profile.d ]; then
    rm -f /etc/profile.d/rec-shell.sh && ok "removed /etc/profile.d/rec-shell.sh"
  else
    skip "no write permission: /etc/profile.d/rec-shell.sh"
  fi
fi

for d in "$HOME/.rec-shell" /opt/rec-shell; do
  [ -d "$d" ] || continue
  if [ -w "$(dirname "$d")" ]; then
    rm -rf "$d" && ok "removed $d"
  else
    skip "no write permission: $d"
  fi
done

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/rec-shell"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/rec-shell"
if [ "$PURGE" -eq 1 ]; then
  rm -rf "$CONFIG_DIR" "$CACHE_DIR"
  ok "purged config and cache"
else
  info "kept config at $CONFIG_DIR (use --purge to remove)"
fi

ok "rec-shell removed. Restart your shell to finish."
