# shellcheck shell=sh
#
# lib/core.sh — shared helpers and environment facts.
# Sourced by rec-shell.sh after REC_SHELL_DIR / REC_SHELL_NAME are known.
# Everything here must be POSIX sh so it loads identically in bash and zsh.

# --- Operating system ------------------------------------------------------
case "$(uname -s 2>/dev/null)" in
  Darwin) REC_OS=mac ;;
  Linux) REC_OS=linux ;;
  *) REC_OS=other ;;
esac
export REC_OS

# --- Standard locations (XDG; deliberately OUTSIDE the git checkout, so a
#     `git pull` update never touches the user's config or cache) -----------
REC_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/rec-shell"
REC_CONFIG_FILE="$REC_CONFIG_DIR/config"
REC_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/rec-shell"
REC_CACHE_FILE="$REC_CACHE_DIR/update"
export REC_CONFIG_DIR REC_CONFIG_FILE REC_CACHE_DIR REC_CACHE_FILE

# --- Helpers ---------------------------------------------------------------

# rec_have CMD -> 0 if CMD exists on PATH, else 1.
rec_have() {
  command -v "$1" >/dev/null 2>&1
}

# rec_warn MESSAGE... -> print a namespaced warning to stderr.
rec_warn() {
  printf 'rec-shell: %s\n' "$*" >&2
}

# rec_installed_version -> print the version from $REC_SHELL_DIR/VERSION,
# with a leading "v" and any surrounding whitespace stripped.
# Returns non-zero (and prints nothing) when the file is missing/empty.
rec_installed_version() {
  [ -n "${REC_SHELL_DIR:-}" ] && [ -r "$REC_SHELL_DIR/VERSION" ] || return 1
  IFS= read -r _rec_v <"$REC_SHELL_DIR/VERSION" 2>/dev/null || return 1
  _rec_v="${_rec_v%"${_rec_v##*[![:space:]]}"}" # strip trailing whitespace/CR
  _rec_v="${_rec_v#"${_rec_v%%[![:space:]]*}"}" # strip leading whitespace
  _rec_v="${_rec_v#v}"
  [ -n "$_rec_v" ] || return 1
  printf '%s' "$_rec_v"
}
