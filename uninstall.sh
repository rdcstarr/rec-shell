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

# Remove the marker line and the loader line that follows it (anchored on the
# marker comment, so it works even if the path changed).
strip_rc() {
  rc="$1"
  [ -f "$rc" ] || return 0
  grep -qF "$MARKER" "$rc" 2>/dev/null || return 0
  if [ ! -w "$rc" ]; then
    printf 'skip (no write permission): %s\n' "$rc" >&2
    return 0
  fi
  tmp="$rc.rec-uninstall.$$"
  awk -v m="$MARKER" '$0 == m { skip = 2 } skip > 0 { skip--; next } { print }' "$rc" >"$tmp" \
    && mv "$tmp" "$rc" \
    && printf 'removed loader line from %s\n' "$rc"
}

for rc in "$HOME/.zshrc" "$HOME/.bashrc" /etc/zshrc /etc/zsh/zshrc /etc/bash.bashrc /etc/bashrc; do
  strip_rc "$rc"
done

for d in "$HOME/.rec-shell" /opt/rec-shell; do
  [ -d "$d" ] || continue
  if [ -w "$(dirname "$d")" ]; then
    rm -rf "$d" && printf 'removed %s\n' "$d"
  else
    printf 'skip (no write permission): %s\n' "$d" >&2
  fi
done

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/rec-shell"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/rec-shell"
if [ "$PURGE" -eq 1 ]; then
  rm -rf "$CONFIG_DIR" "$CACHE_DIR"
  printf 'purged config and cache\n'
else
  printf 'kept config at %s (use --purge to remove)\n' "$CONFIG_DIR"
fi

printf 'rec-shell removed. Restart your shell to finish.\n'
