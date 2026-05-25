# shellcheck shell=bash
# shellcheck disable=SC1090,SC1091,SC2317 # loader sources files by path; return||exit guards a sourced-or-executed file
#
# rec-shell.sh — the loader. This is the ONE file your shell rc sources:
#
#   # rec-shell
#   [ -f "$HOME/.rec-shell/rec-shell.sh" ] && . "$HOME/.rec-shell/rec-shell.sh"
#
# It runs under both bash and zsh. Keep the top dependency-free until the
# shell and the install directory are known.

# 1) Interactive shells only. Tolerate being executed instead of sourced.
case "$-" in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac

# 2) Double-load guard. `rec-shell reload` unsets this, then re-sources us.
[ -n "${REC_SHELL_LOADED:-}" ] && return 0
REC_SHELL_LOADED=1

# 3) Identify the shell and resolve THIS file's directory while being sourced.
if [ -n "${ZSH_VERSION:-}" ]; then
  REC_SHELL_NAME=zsh
  # zsh-only expansion, hidden from bash's parser inside eval:
  #   ${(%):-%x} = path of the file being sourced; :A = absolute+symlink-resolved; :h = dirname
  eval 'REC_SHELL_DIR="${${(%):-%x}:A:h}"'
elif [ -n "${BASH_VERSION:-}" ]; then
  REC_SHELL_NAME=bash
  REC_SHELL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
else
  return 0 2>/dev/null || exit 0 # unsupported shell (sh/dash/fish)
fi
export REC_SHELL_NAME REC_SHELL_DIR

# 4) Core helpers are required; the rest degrade gracefully (partial installs).
if [ -r "$REC_SHELL_DIR/lib/core.sh" ]; then
  . "$REC_SHELL_DIR/lib/core.sh"
else
  return 0 2>/dev/null || exit 0
fi
# UI toolkit before update.sh, so the "new version" banner can use it.
[ -r "$REC_SHELL_DIR/lib/ui.sh" ] && . "$REC_SHELL_DIR/lib/ui.sh"
[ -r "$REC_SHELL_DIR/lib/semver.sh" ] && . "$REC_SHELL_DIR/lib/semver.sh"
[ -r "$REC_SHELL_DIR/lib/update.sh" ] && . "$REC_SHELL_DIR/lib/update.sh"

# 5) Configuration: system-wide default first, then per-user override.
#    Both live OUTSIDE the checkout, so updates never clobber them.
[ -r /etc/rec-shell/config ] && . /etc/rec-shell/config
[ -r "${REC_CONFIG_FILE:-}" ] && . "$REC_CONFIG_FILE"

# 6) Load modules in numeric order, skipping any listed in REC_DISABLED_MODULES.
#    Neutralize two shell differences around the glob:
#      - LC_ALL=C        -> identical sort order in bash and zsh
#      - zsh NOMATCH     -> zsh aborts on a non-matching glob; make it leave the
#                           pattern literal (like bash) so an empty modules/ dir
#                           is harmless, then restore the user's setting.
_rec_old_lc="${LC_ALL:-}"
LC_ALL=C
_rec_nomatch_restore=""
if [ -n "${ZSH_VERSION:-}" ]; then
  eval '[[ -o nomatch ]] && _rec_nomatch_restore=1; setopt no_nomatch'
fi
_rec_disabled=" ${REC_DISABLED_MODULES:-} "
for _rec_mod in "$REC_SHELL_DIR"/modules/*.sh; do
  [ -r "$_rec_mod" ] || continue # skips the literal pattern when nothing matches
  _rec_key="${_rec_mod##*/}"
  _rec_key="${_rec_key%.sh}"
  _rec_key="${_rec_key#[0-9][0-9]-}" # strip the NN- ordering prefix
  case "$_rec_disabled" in
    *" $_rec_key "*) continue ;;
  esac
  . "$_rec_mod"
done
[ -n "$_rec_nomatch_restore" ] && eval 'setopt nomatch'
if [ -n "$_rec_old_lc" ]; then LC_ALL="$_rec_old_lc"; else unset LC_ALL; fi
unset _rec_mod _rec_key _rec_disabled _rec_old_lc _rec_nomatch_restore

# 7) The `rec` command. A function (not a PATH script) so `reload` and `update`
#    can re-source the live shell, lazy-loaded on first use. `rec-shell` stays
#    available as a back-compat alias.
rec() {
  if ! command -v __rec_dispatch >/dev/null 2>&1; then
    if [ -r "$REC_SHELL_DIR/lib/cli.sh" ]; then
      . "$REC_SHELL_DIR/lib/cli.sh"
    else
      printf 'rec-shell: CLI not found at %s\n' "$REC_SHELL_DIR/lib/cli.sh" >&2
      return 1
    fi
  fi
  __rec_dispatch "$@"
}
# Back-compat: keep the old `rec-shell` command name working. A function (not an
# alias) so it resolves at call time and has no alias parse-order surprises.
rec-shell() { rec "$@"; }

# 8) User overrides, sourced LAST so they always win.
if [ "$REC_SHELL_NAME" = zsh ] && [ -r "$HOME/.zsh_aliases" ]; then
  . "$HOME/.zsh_aliases" # back-compat with the previous setup
elif [ "$REC_SHELL_NAME" = bash ] && [ -r "$HOME/.bash_aliases" ]; then
  . "$HOME/.bash_aliases" # back-compat with the previous setup
fi
[ -r "$HOME/.rec-shell.local" ] && . "$HOME/.rec-shell.local"

# 9) Non-blocking, throttled "new version available" check (ddev-style).
command -v rec_update_startup >/dev/null 2>&1 && rec_update_startup
