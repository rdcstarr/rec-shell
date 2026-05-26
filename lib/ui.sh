# shellcheck shell=sh
# shellcheck disable=SC1090,SC1091 # we source the interactive widgets by path
#
# lib/ui.sh — the rec-shell output toolkit: one consistent, "minimal modern"
# look for every message (inspired by Laravel Prompts). Sourced by the loader
# right after lib/core.sh so the update banner and the lazy CLI can both use it.
#
# Everything here is POSIX sh (it loads at startup in bash AND zsh) and does no
# work beyond defining functions plus a single, fork-free capability probe.
# The richer INTERACTIVE widgets (confirm/select/spinner) live in
# lib/ui-interactive.sh and are loaded on demand via rec_ui_interactive_load.
#
# Keep the glyphs/colors here in sync with the embedded copies in install.sh
# and uninstall.sh (those run standalone, before this file can be sourced).

# --- capability probe (run once, at source time) ---------------------------
#
# Color decision, highest priority first:
#   1. NO_COLOR / REC_NO_COLOR / REC_UI_PLAIN set -> never color (user opt-out).
#   2. CLICOLOR_FORCE set (and not 0)            -> always color, even if piped.
#   3. otherwise                                 -> color only on a TTY, per
#                                                   stream (stdout vs stderr).
__rec_ui_init() {
  _rui_off=no
  [ "${NO_COLOR+x}" = x ] && _rui_off=yes
  [ -n "${REC_NO_COLOR:-}" ] && _rui_off=yes
  [ -n "${REC_UI_PLAIN:-}" ] && _rui_off=yes

  _rui_force=no
  case "${CLICOLOR_FORCE:-}" in
    '' | 0) ;;
    *) _rui_force=yes ;;
  esac

  if [ "$_rui_off" = yes ]; then
    REC_UI_C1=0
    REC_UI_C2=0
  elif [ "$_rui_force" = yes ]; then
    REC_UI_C1=1
    REC_UI_C2=1
  else
    if [ -t 1 ]; then REC_UI_C1=1; else REC_UI_C1=0; fi
    if [ -t 2 ]; then REC_UI_C2=1; else REC_UI_C2=0; fi
  fi

  # SGR numbers only; assembled into escapes at print time by __rec_ui_emit.
  REC_UI_S_GREEN=32
  REC_UI_S_RED=31
  REC_UI_S_YELLOW=33
  REC_UI_S_CYAN=36
  REC_UI_S_DIM=2
  REC_UI_S_BOLD=1

  __rec_ui_init_glyphs
  unset _rui_off _rui_force
}

# Pick Unicode or ASCII glyphs. ASCII when REC_UI_ASCII is set, or when the
# locale is not UTF-8 (so we never print mojibake on a Latin-1/C terminal).
# Some glyphs (gutter/checkbox/UTF flag) are consumed only by ui-interactive.sh.
# shellcheck disable=SC2034 # cross-file palette: read by lib/ui-interactive.sh
__rec_ui_init_glyphs() {
  _rui_utf=no
  case "${REC_UI_ASCII:-}" in
    1 | yes | true | on) ;;
    *)
      # POSIX locale precedence: LC_ALL overrides LC_CTYPE overrides LANG.
      _rui_loc=${LC_ALL:-${LC_CTYPE:-${LANG:-}}}
      case "$_rui_loc" in
        *[Uu][Tt][Ff]8* | *[Uu][Tt][Ff]-8*) _rui_utf=yes ;;
      esac
      unset _rui_loc
      ;;
  esac

  REC_UI_UTF=$_rui_utf
  if [ "$_rui_utf" = yes ]; then
    REC_UI_G_OK='✓'
    REC_UI_G_ERR='✗'
    REC_UI_G_WARN='⚠'
    REC_UI_G_INFO='ℹ'
    REC_UI_G_ARROW='➜'
    REC_UI_G_GT='›'
    REC_UI_G_ON='◼'
    REC_UI_G_OFF='◻'
    REC_UI_G_V='│'
    REC_UI_G_TL='┌'
    REC_UI_G_BL='└'
    REC_UI_G_H='─'
  else
    REC_UI_G_OK='[ok]'
    REC_UI_G_ERR='[x]'
    REC_UI_G_WARN='[!]'
    REC_UI_G_INFO='[i]'
    REC_UI_G_ARROW='->'
    REC_UI_G_GT='>'
    REC_UI_G_ON='[x]'
    REC_UI_G_OFF='[ ]'
    REC_UI_G_V='|'
    REC_UI_G_TL='+'
    REC_UI_G_BL='+'
    REC_UI_G_H='-'
  fi
  unset _rui_utf
}

# --- the single coloring chokepoint ----------------------------------------
#
# __rec_ui_emit STREAM SGR TEXT...  ->  print TEXT, wrapped in the SGR color
# only when that STREAM (1=stdout, 2=stderr) is allowed to use color. This is
# what makes everything auto-degrade to plain text when output is piped.
__rec_ui_emit() {
  _rui_s=$1
  _rui_sgr=$2
  shift 2
  if [ "$_rui_s" = 2 ]; then _rui_on=$REC_UI_C2; else _rui_on=$REC_UI_C1; fi
  if [ -n "$_rui_sgr" ] && [ "$_rui_on" = 1 ]; then
    printf '\033[%sm%s\033[0m' "$_rui_sgr" "$*"
  else
    printf '%s' "$*"
  fi
}

# --- static message API ----------------------------------------------------
#
# Status lines are "<glyph> <message>". Informational output goes to stdout;
# errors and warnings go to stderr (rec_ui_warn_out is the stdout variant used
# by `rec doctor`, whose diagnostics are all expected on stdout).

rec_ui_ok() {
  __rec_ui_emit 1 "$REC_UI_S_GREEN" "$REC_UI_G_OK"
  printf ' %s\n' "$*"
}

rec_ui_err() {
  {
    __rec_ui_emit 2 "$REC_UI_S_RED" "$REC_UI_G_ERR"
    printf ' %s\n' "$*"
  } >&2
}

rec_ui_warn() {
  {
    __rec_ui_emit 2 "$REC_UI_S_YELLOW" "$REC_UI_G_WARN"
    printf ' %s\n' "$*"
  } >&2
}

rec_ui_warn_out() {
  __rec_ui_emit 1 "$REC_UI_S_YELLOW" "$REC_UI_G_WARN"
  printf ' %s\n' "$*"
}

rec_ui_info() {
  __rec_ui_emit 1 "$REC_UI_S_CYAN" "$REC_UI_G_INFO"
  printf ' %s\n' "$*"
}

rec_ui_step() {
  __rec_ui_emit 1 "$REC_UI_S_CYAN" "$REC_UI_G_ARROW"
  printf ' %s\n' "$*"
}

# rec_ui_kv KEY VALUE... -> a dim, left-aligned key followed by its value.
rec_ui_kv() {
  _rui_k=$1
  shift
  __rec_ui_emit 1 "$REC_UI_S_DIM" "$(printf '%-10s' "$_rui_k:")"
  printf ' %s\n' "$*"
}

# rec_ui_heading TITLE... -> a bold title line.
rec_ui_heading() {
  __rec_ui_emit 1 "$REC_UI_S_BOLD" "$*"
  printf '\n'
}

# rec_ui_note MESSAGE... -> a dim gutter bar followed by the message.
rec_ui_note() {
  __rec_ui_emit 1 "$REC_UI_S_DIM" "$REC_UI_G_V"
  printf ' %s\n' "$*"
}

# rec_ui_hr -> a dim horizontal rule, capped at 60 columns.
rec_ui_hr() {
  _rui_w=$(__rec_ui_cols)
  case "$_rui_w" in '' | *[!0-9]*) _rui_w=80 ;; esac
  [ "$_rui_w" -gt 60 ] && _rui_w=60
  _rui_line=''
  _rui_i=0
  while [ "$_rui_i" -lt "$_rui_w" ]; do
    _rui_line="$_rui_line$REC_UI_G_H"
    _rui_i=$((_rui_i + 1))
  done
  __rec_ui_emit 1 "$REC_UI_S_DIM" "$_rui_line"
  printf '\n'
}

# rec_ui_box LINE... -> each argument framed inside a cyan rounded box gutter.
rec_ui_box() {
  __rec_ui_emit 1 "$REC_UI_S_CYAN" "$REC_UI_G_TL$REC_UI_G_H"
  printf '\n'
  for _rui_l in "$@"; do
    __rec_ui_emit 1 "$REC_UI_S_CYAN" "$REC_UI_G_V"
    printf ' %s\n' "$_rui_l"
  done
  __rec_ui_emit 1 "$REC_UI_S_CYAN" "$REC_UI_G_BL$REC_UI_G_H"
  printf '\n'
}

# --- terminal helpers ------------------------------------------------------

# __rec_ui_cols -> terminal width, no fork when $COLUMNS is set.
__rec_ui_cols() {
  if [ -n "${COLUMNS:-}" ]; then
    printf '%s' "$COLUMNS"
  elif [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    tput cols 2>/dev/null || printf '80'
  else
    printf '80'
  fi
}

# --- lazy loader for the interactive widgets -------------------------------

# rec_ui_interactive_load -> source lib/ui-interactive.sh once (returns 1 if it
# is unavailable, e.g. a partial install).
rec_ui_interactive_load() {
  command -v __rec_ui_interactive >/dev/null 2>&1 && return 0
  [ -n "${REC_SHELL_DIR:-}" ] && [ -r "$REC_SHELL_DIR/lib/ui-interactive.sh" ] || return 1
  . "$REC_SHELL_DIR/lib/ui-interactive.sh"
}

# rec_banner [version] [subtitle] [hint] -> the rec-shell brand banner.
#
# Three-line cyan logo + an optional dim version line + optional subtitle +
# optional arrow hint. Used by `rec version`, the tail of `rec update`, and
# the tail of install.sh (which carries an equivalent inline copy). All
# arguments are optional — calling `rec_banner` with no args prints just the
# logo, which is fine for cosmetic contexts.
#
# Respects the same color/UTF rules as the rest of the toolkit: NO_COLOR /
# REC_UI_PLAIN turn off color; non-UTF locales (or REC_UI_ASCII=1) fall back
# to a plain block-letter version that renders on any terminal.
rec_banner() {
  _rbn_v="${1:-}"
  _rbn_sub="${2:-}"
  _rbn_hint="${3:-}"
  if [ "${REC_UI_UTF:-no}" = yes ]; then
    __rec_ui_emit 1 "$REC_UI_S_CYAN" '   ┏━┓┏━╸┏━╸    ┏━╸╻ ╻┏━╸╻  ╻'
    printf '\n'
    __rec_ui_emit 1 "$REC_UI_S_CYAN" '   ┣┳┛┣╸ ┃      ┗━┓┣━┫┣╸ ┃  ┃'
    printf '\n'
    __rec_ui_emit 1 "$REC_UI_S_CYAN" '   ╹┗╸┗━╸┗━╸    ┗━┛╹ ╹┗━╸┗━╸┗━╸'
    printf '\n'
  else
    __rec_ui_emit 1 "$REC_UI_S_CYAN" '   ___  ___  ___      ___ _  _ ___ _   _   '
    printf '\n'
    __rec_ui_emit 1 "$REC_UI_S_CYAN" '  | _ \| __|/ __|    / __| || | __| | | |  '
    printf '\n'
    __rec_ui_emit 1 "$REC_UI_S_CYAN" '  |   /| _|| (__     \__ \ __ | _|| |_| |_ '
    printf '\n'
    __rec_ui_emit 1 "$REC_UI_S_CYAN" '  |_|_\|___|\___|    |___/_||_|___|___|___|'
    printf '\n'
  fi
  printf '\n'
  if [ -n "$_rbn_v" ]; then
    __rec_ui_emit 1 "$REC_UI_S_DIM" "   modern bash & zsh  $REC_UI_G_GT  v$_rbn_v"
    printf '\n'
  fi
  if [ -n "$_rbn_sub" ]; then
    __rec_ui_emit 1 "$REC_UI_S_DIM" "   $_rbn_sub"
    printf '\n'
  fi
  if [ -n "$_rbn_hint" ]; then
    __rec_ui_emit 1 "$REC_UI_S_DIM" "   $REC_UI_G_ARROW $_rbn_hint"
    printf '\n'
  fi
  unset _rbn_v _rbn_sub _rbn_hint
}

__rec_ui_init
