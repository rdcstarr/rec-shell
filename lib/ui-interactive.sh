# shellcheck shell=bash
#
# lib/ui-interactive.sh — interactive widgets for rec-shell, in the Laravel
# Prompts idiom: confirm, select, multiselect, input and a spinner. Loaded on
# demand by rec_ui_interactive_load (lib/ui.sh); never sourced at startup.
#
# Every widget guards on __rec_ui_interactive first: on a real terminal it
# drives a raw-key TUI; otherwise it takes a non-blocking fallback (a default,
# the first option, or a synchronous run) so scripts and CI never hang. The
# raw-key paths use bash/zsh-specific reads branched on $REC_SHELL_NAME; the
# fallbacks stay POSIX so this file is still safe to source under any sh.
#
# Convention: the live TUI is drawn to stderr and the chosen RESULT is printed
# to stdout, so `value=$(rec_ui_select ...)` works with the menu still visible.

# --- gates & primitives ----------------------------------------------------

# __rec_ui_interactive -> 0 only when we can safely drive a TUI on this term.
# We require a terminal on stdin (we read keys) and stderr (we draw the UI);
# stdout is deliberately NOT required, so `value=$(rec_ui_select ...)` still
# shows the menu when the result is captured via command substitution.
__rec_ui_interactive() {
  [ -t 0 ] && [ -t 2 ] || return 1
  [ -n "${REC_UI_PLAIN:-}" ] && return 1
  case "${TERM:-}" in
    dumb | '') return 1 ;;
  esac
  return 0
}

# __rec_ui_readkey -> read ONE keypress and print a logical name:
#   up/down/left/right, enter, space, esc, or the literal character.
# Solves the bash vs zsh single-key read difference in one place.
__rec_ui_readkey() {
  _rui_nl='
'
  _rui_cr=$(printf '\r')
  _rui_esc=$(printf '\033')
  if [ "${REC_SHELL_NAME:-}" = zsh ]; then
    read -rsk1 _rui_k 2>/dev/null
  else
    IFS= read -rsn1 _rui_k 2>/dev/null
  fi
  case "$_rui_k" in
    '' | "$_rui_nl" | "$_rui_cr")
      printf 'enter'
      return
      ;;
    ' ')
      printf 'space'
      return
      ;;
    "$_rui_esc") ;;
    *)
      printf '%s' "$_rui_k"
      return
      ;;
  esac
  # We saw ESC: read the rest of the CSI arrow sequence (2 more bytes).
  if [ "${REC_SHELL_NAME:-}" = zsh ]; then
    read -rsk2 _rui_rest 2>/dev/null
  else
    IFS= read -rsn2 _rui_rest 2>/dev/null
  fi
  case "$_rui_rest" in
    '[A') printf 'up' ;;
    '[B') printf 'down' ;;
    '[C') printf 'right' ;;
    '[D') printf 'left' ;;
    *) printf 'esc' ;;
  esac
}

# __rec_ui_spin_frame INDEX -> one animation glyph (Unicode braille or ASCII).
__rec_ui_spin_frame() {
  if [ "${REC_UI_UTF:-no}" = yes ]; then
    case "$1" in
      0) printf '⠋' ;;
      1) printf '⠙' ;;
      2) printf '⠹' ;;
      3) printf '⠸' ;;
      4) printf '⠼' ;;
      5) printf '⠴' ;;
      6) printf '⠦' ;;
      7) printf '⠧' ;;
      8) printf '⠇' ;;
      *) printf '⠏' ;;
    esac
  else
    case "$1" in
      0 | 4 | 8) printf '|' ;;
      1 | 5 | 9) printf '/' ;;
      2 | 6) printf '-' ;;
      *) printf '\134' ;; # octal for a single backslash
    esac
  fi
}

__rec_ui_sleep_frame() {
  sleep 0.08 2>/dev/null || sleep 1
}

# --- confirm ---------------------------------------------------------------

# rec_ui_confirm PROMPT [yes|no] -> 0 for yes, 1 for no. Non-TTY: the default.
rec_ui_confirm() {
  _rui_prompt=$1
  _rui_def=${2:-no}
  if ! __rec_ui_interactive; then
    case "$_rui_def" in
      y | Y | yes | YES | Yes | true | 1 | on) return 0 ;;
      *) return 1 ;;
    esac
  fi
  __rec_ui_confirm_tui "$_rui_prompt" "$_rui_def"
}

__rec_ui_confirm_tui() {
  _rui_prompt=$1
  case "$2" in
    y | Y | yes | YES | Yes | true | 1 | on) _rui_yes=1 ;;
    *) _rui_yes=0 ;;
  esac
  {
    __rec_ui_emit 1 "$REC_UI_S_CYAN" "$REC_UI_G_TL"
    printf ' %s\n' "$_rui_prompt"
    printf '\033[?25l'
    _rui_first=1
    while :; do
      [ "$_rui_first" = 1 ] || printf '\033[1A'
      _rui_first=0
      printf '\r\033[2K'
      __rec_ui_emit 1 "$REC_UI_S_CYAN" "$REC_UI_G_V"
      printf ' '
      if [ "$_rui_yes" = 1 ]; then
        __rec_ui_emit 1 "$REC_UI_S_CYAN" "$REC_UI_G_GT Yes"
        printf '   No\n'
      else
        printf '  Yes   '
        __rec_ui_emit 1 "$REC_UI_S_CYAN" "$REC_UI_G_GT No"
        printf '\n'
      fi
      _rui_key=$(__rec_ui_readkey)
      case "$_rui_key" in
        left | right | up | down)
          if [ "$_rui_yes" = 1 ]; then _rui_yes=0; else _rui_yes=1; fi
          ;;
        y | Y)
          _rui_yes=1
          break
          ;;
        n | N)
          _rui_yes=0
          break
          ;;
        enter) break ;;
        esc | q)
          printf '\033[?25h'
          return 130
          ;;
      esac
    done
    printf '\033[?25h'
  } >&2
  [ "$_rui_yes" = 1 ]
}

# --- select ----------------------------------------------------------------

# rec_ui_select PROMPT OPT... -> print the chosen value on stdout.
# Non-TTY: the first option.
rec_ui_select() {
  _rui_prompt=$1
  shift
  if ! __rec_ui_interactive; then
    [ $# -ge 1 ] && printf '%s\n' "$1"
    return 0
  fi
  __rec_ui_select_tui "$_rui_prompt" "$@"
}

__rec_ui_select_tui() {
  _rui_prompt=$1
  shift
  _rui_n=$#
  _rui_sel=1
  {
    __rec_ui_emit 1 "$REC_UI_S_CYAN" "$REC_UI_G_TL"
    printf ' %s\n' "$_rui_prompt"
    printf '\033[?25l'
    _rui_first=1
    while :; do
      [ "$_rui_first" = 1 ] || printf '\033[%dA' "$_rui_n"
      _rui_first=0
      _rui_idx=1
      for _rui_opt in "$@"; do
        printf '\r\033[2K'
        __rec_ui_emit 1 "$REC_UI_S_CYAN" "$REC_UI_G_V"
        if [ "$_rui_idx" = "$_rui_sel" ]; then
          printf ' '
          __rec_ui_emit 1 "$REC_UI_S_CYAN" "$REC_UI_G_GT $_rui_opt"
          printf '\n'
        else
          printf '   %s\n' "$_rui_opt"
        fi
        _rui_idx=$((_rui_idx + 1))
      done
      _rui_key=$(__rec_ui_readkey)
      case "$_rui_key" in
        up)
          _rui_sel=$((_rui_sel - 1))
          [ "$_rui_sel" -lt 1 ] && _rui_sel=$_rui_n
          ;;
        down)
          _rui_sel=$((_rui_sel + 1))
          [ "$_rui_sel" -gt "$_rui_n" ] && _rui_sel=1
          ;;
        enter) break ;;
        esc | q)
          printf '\033[?25h'
          return 130
          ;;
      esac
    done
    printf '\033[?25h'
  } >&2
  _rui_idx=1
  for _rui_opt in "$@"; do
    if [ "$_rui_idx" = "$_rui_sel" ]; then
      printf '%s\n' "$_rui_opt"
      break
    fi
    _rui_idx=$((_rui_idx + 1))
  done
}

# --- multiselect -----------------------------------------------------------

# rec_ui_multiselect PROMPT OPT... -> print each chosen value (one per line) on
# stdout; also collected (space-separated) in REC_UI_REPLY. Non-TTY: nothing.
rec_ui_multiselect() {
  _rui_prompt=$1
  shift
  REC_UI_REPLY=''
  if ! __rec_ui_interactive; then
    return 0
  fi
  __rec_ui_multiselect_tui "$_rui_prompt" "$@"
}

__rec_ui_multiselect_tui() {
  _rui_prompt=$1
  shift
  _rui_n=$#
  _rui_sel=1
  _rui_marks=' '
  {
    __rec_ui_emit 1 "$REC_UI_S_CYAN" "$REC_UI_G_TL"
    printf ' %s' "$_rui_prompt"
    __rec_ui_emit 1 "$REC_UI_S_DIM" '  (space toggles · a all · enter confirms)'
    printf '\n'
    printf '\033[?25l'
    _rui_first=1
    while :; do
      [ "$_rui_first" = 1 ] || printf '\033[%dA' "$_rui_n"
      _rui_first=0
      _rui_idx=1
      for _rui_opt in "$@"; do
        printf '\r\033[2K'
        __rec_ui_emit 1 "$REC_UI_S_CYAN" "$REC_UI_G_V"
        printf ' '
        case "$_rui_marks" in
          *" $_rui_idx "*) _rui_box=$REC_UI_G_ON ;;
          *) _rui_box=$REC_UI_G_OFF ;;
        esac
        if [ "$_rui_idx" = "$_rui_sel" ]; then
          __rec_ui_emit 1 "$REC_UI_S_CYAN" "$REC_UI_G_GT $_rui_box $_rui_opt"
        else
          printf '  %s %s' "$_rui_box" "$_rui_opt"
        fi
        printf '\n'
        _rui_idx=$((_rui_idx + 1))
      done
      _rui_key=$(__rec_ui_readkey)
      case "$_rui_key" in
        up)
          _rui_sel=$((_rui_sel - 1))
          [ "$_rui_sel" -lt 1 ] && _rui_sel=$_rui_n
          ;;
        down)
          _rui_sel=$((_rui_sel + 1))
          [ "$_rui_sel" -gt "$_rui_n" ] && _rui_sel=1
          ;;
        space)
          case "$_rui_marks" in
            *" $_rui_sel "*) _rui_marks=$(printf '%s' "$_rui_marks" | sed "s/ $_rui_sel / /") ;;
            *) _rui_marks="$_rui_marks$_rui_sel " ;;
          esac
          ;;
        a | A)
          _rui_marks=' '
          _rui_idx=1
          while [ "$_rui_idx" -le "$_rui_n" ]; do
            _rui_marks="$_rui_marks$_rui_idx "
            _rui_idx=$((_rui_idx + 1))
          done
          ;;
        enter) break ;;
        esc | q)
          printf '\033[?25h'
          return 130
          ;;
      esac
    done
    printf '\033[?25h'
  } >&2
  _rui_idx=1
  for _rui_opt in "$@"; do
    case "$_rui_marks" in
      *" $_rui_idx "*)
        printf '%s\n' "$_rui_opt"
        REC_UI_REPLY="$REC_UI_REPLY$_rui_opt "
        ;;
    esac
    _rui_idx=$((_rui_idx + 1))
  done
}

# --- input -----------------------------------------------------------------

# rec_ui_input PROMPT [default] -> print the entered value (default on empty
# or when non-interactive).
rec_ui_input() {
  _rui_prompt=$1
  _rui_def=${2:-}
  if ! __rec_ui_interactive; then
    printf '%s' "$_rui_def"
    return 0
  fi
  {
    __rec_ui_emit 1 "$REC_UI_S_CYAN" "$REC_UI_G_TL"
    printf ' %s' "$_rui_prompt"
    if [ -n "$_rui_def" ]; then
      printf ' '
      __rec_ui_emit 1 "$REC_UI_S_DIM" "[$_rui_def]"
    fi
    printf '\n'
    __rec_ui_emit 1 "$REC_UI_S_CYAN" "$REC_UI_G_V"
    printf ' '
  } >&2
  read -r _rui_val || _rui_val=''
  [ -z "$_rui_val" ] && _rui_val=$_rui_def
  printf '%s' "$_rui_val"
}

# --- spinner ---------------------------------------------------------------

# rec_ui_spin LABEL CMD [ARG...] -> run CMD with a spinner; print ✓/✗ + LABEL;
# return CMD's exit code. Non-TTY: run synchronously (no animation, no hang).
rec_ui_spin() {
  _rui_label=$1
  shift
  if ! __rec_ui_interactive; then
    "$@"
    _rui_rc=$?
    if [ "$_rui_rc" -eq 0 ]; then rec_ui_ok "$_rui_label"; else rec_ui_err "$_rui_label"; fi
    return "$_rui_rc"
  fi

  "$@" >/dev/null 2>&1 &
  _rui_pid=$!
  trap '__rec_ui_spin_cleanup "$_rui_pid"' INT TERM
  {
    printf '\033[?25l'
    _rui_i=0
    while kill -0 "$_rui_pid" 2>/dev/null; do
      printf '\r'
      __rec_ui_emit 1 "$REC_UI_S_CYAN" "$(__rec_ui_spin_frame "$_rui_i")"
      printf ' %s' "$_rui_label"
      _rui_i=$(((_rui_i + 1) % 10))
      __rec_ui_sleep_frame
    done
    printf '\r\033[2K\033[?25h'
  } >&2
  wait "$_rui_pid"
  _rui_rc=$?
  trap - INT TERM
  if [ "$_rui_rc" -eq 0 ]; then rec_ui_ok "$_rui_label"; else rec_ui_err "$_rui_label"; fi
  return "$_rui_rc"
}

__rec_ui_spin_cleanup() {
  kill "$1" 2>/dev/null
  printf '\r\033[2K\033[?25h' >&2
  trap - INT TERM
  kill -INT $$ 2>/dev/null
}
