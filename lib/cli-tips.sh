# shellcheck shell=bash
#
# lib/cli-tips.sh — `rec tips` (one tip at a time) and `rec cheat` (full
# cheatsheet) for the modern CLI tools rec-shell can install. Tips are
# filtered to what's actually on PATH so the user never sees a hint for a
# tool they haven't installed.
#
#   rec tips             one random tip (filtered to installed tools)
#   rec tips next        cycle: print the next tip in the rotation
#   rec tips all         every applicable tip, grouped by tool
#   rec cheat            cheatsheet sections for every installed tool
#   rec cheat <tool>     just that tool's section

# Tips database. Each entry is `<tool-key>|<one-line tip>`. The tool-key is
# checked with rec_have to filter the list at runtime.
REC_TIPS=(
  "rg|rg 'pattern' -t py — search only Python files"
  "rg|rg --hidden 'pattern' — include dotfiles"
  "rg|rg -l 'pattern' — list matching files only"
  "rg|rg -A 2 -B 2 'pattern' — show 2 lines of context"
  "fd|fd '\.rs$' src — find Rust files under src/"
  "fd|fd -e jpg -X mogrify -resize 800x — pipe matches into a command"
  "fd|fd -t d node_modules -x rm -rf — clean every node_modules in a tree"
  "fd|fd -H -E .git — search hidden files, exclude .git"
  "eza|eza --tree --level=2 — visual two-level tree"
  "eza|eza -l --sort=size — largest files first"
  "eza|eza -l --git — show git status next to each file"
  "eza|eza --total-size -l — show recursive sizes per directory"
  "bat|bat -p file.json | jq . — bat as syntax-highlighting pager"
  "bat|bat --diff old.txt new.txt — colorful diff"
  "bat|tail -f log.txt | bat --paging=never -l log — live-tail with colors"
  "atuin|Ctrl+R — fuzzy through ALL history (with timestamps, exit codes)"
  "atuin|atuin search --cwd . — recall commands run in this directory"
  "atuin|atuin stats — top commands and frequency"
  "fzf|Ctrl+T — fuzzy pick a file into the current command"
  "fzf|Alt+C — fuzzy cd to any subdirectory"
  "fzf|kill -9 \$(ps aux | fzf | awk '{print \$2}') — interactive kill"
  "btop|btop — full-screen interactive top (mouse + gradient bars)"
  "btop|btop --preset 0 — minimal preset; F2 in btop to switch"
  "ncdu|ncdu -x / — interactive disk usage on the root filesystem"
  "ncdu|ncdu --exclude .git . — skip git history while scanning"
)

# Print a tip if its tool is installed. Skips silently otherwise.
__rec_tip_emit() {
  local entry="$1" tool tip
  tool="${entry%%|*}"
  tip="${entry#*|}"
  rec_have "$tool" || return 1
  rec_ui_kv "[$tool]" "$tip"
}

# Return the indices (newline-separated) of REC_TIPS entries that apply to
# what's installed on this host. POSIX-portable across bash and zsh.
__rec_tips_applicable_indices() {
  local i n tool
  n="${#REC_TIPS[@]}"
  i=0
  while [ "$i" -lt "$n" ]; do
    tool="${REC_TIPS[$i]%%|*}"
    rec_have "$tool" && printf '%s\n' "$i"
    i=$((i + 1))
  done
}

# Print one random tip from the applicable pool. Quiet (no output) when no
# applicable tools are installed.
__rec_tip_random() {
  local indices count idx pick
  indices="$(__rec_tips_applicable_indices)"
  [ -z "$indices" ] && return 0
  count="$(printf '%s\n' "$indices" | wc -l | awk '{print $1}')"
  # awk is universally available and gives us a uniform random pick.
  pick="$(awk -v n="$count" 'BEGIN { srand(); print int(rand() * n) + 1 }')"
  idx="$(printf '%s\n' "$indices" | sed -n "${pick}p")"
  __rec_tip_emit "${REC_TIPS[$idx]}"
}

# Cycle through the applicable pool. State lives in $REC_CACHE_DIR/tips-index.
__rec_tip_next() {
  local indices count next_pos idx
  indices="$(__rec_tips_applicable_indices)"
  [ -z "$indices" ] && {
    rec_ui_info 'no tips applicable (no modern CLI tools installed yet)'
    return 0
  }
  count="$(printf '%s\n' "$indices" | wc -l | awk '{print $1}')"
  mkdir -p "$REC_CACHE_DIR" 2>/dev/null
  local state="$REC_CACHE_DIR/tips-index"
  next_pos=0
  [ -r "$state" ] && next_pos="$(cat "$state" 2>/dev/null)"
  case "$next_pos" in '' | *[!0-9]*) next_pos=0 ;; esac
  next_pos=$((next_pos % count))
  idx="$(printf '%s\n' "$indices" | sed -n "$((next_pos + 1))p")"
  __rec_tip_emit "${REC_TIPS[$idx]}"
  printf '%s\n' "$((next_pos + 1))" >"$state"
}

# Print every applicable tip, grouped by tool.
__rec_tips_all() {
  local indices last_tool="" idx entry tool any=0
  indices="$(__rec_tips_applicable_indices)"
  [ -z "$indices" ] && {
    rec_ui_info 'no tips applicable (no modern CLI tools installed yet)'
    return 0
  }
  while IFS= read -r idx; do
    entry="${REC_TIPS[$idx]}"
    tool="${entry%%|*}"
    if [ "$tool" != "$last_tool" ]; then
      [ "$any" -eq 1 ] && printf '\n'
      rec_ui_heading "$tool"
      last_tool="$tool"
      any=1
    fi
    printf '  %s\n' "${entry#*|}"
  done <<EOF
$indices
EOF
}

__rec_tips_help() {
  cat <<'EOF'
rec tips — quick reminders for the modern CLI tools you have installed

Usage:
  rec tips         Print one random tip applicable to your install.
  rec tips next    Print the next tip in a stable rotation.
  rec tips all     Print every applicable tip, grouped by tool.
EOF
}

__rec_tips_dispatch() {
  _rti_cmd="${1:-random}"
  [ $# -gt 0 ] && shift
  case "$_rti_cmd" in
    random) __rec_tip_random ;;
    next) __rec_tip_next ;;
    all) __rec_tips_all ;;
    help | --help | -h) __rec_tips_help ;;
    *)
      rec_ui_err "rec tips: unknown command \"$_rti_cmd\""
      printf '\n' >&2
      __rec_tips_help >&2
      return 2
      ;;
  esac
}

# --- cheatsheet -------------------------------------------------------------
# One function per tool; each prints a tiny block of "I always forget how to
# do X" recipes. Kept short so `rec cheat` (the unfiltered call) still fits
# in a screen.

__rec_cheat_section() {
  rec_ui_heading "$1"
  shift
  local line
  for line in "$@"; do printf '  %s\n' "$line"; done
  printf '\n'
}

__rec_cheat_rg() {
  __rec_cheat_section "ripgrep (rg)" \
    "rg 'pattern'              recursive case-smart search" \
    "rg -i 'pattern'           force case-insensitive" \
    "rg -t py 'pattern'        only Python files (see: rg --type-list)" \
    "rg -l 'pattern'           list matching files" \
    "rg -A 2 -B 2 'pattern'    2 lines of context above + below" \
    "rg --hidden --no-ignore   search hidden + gitignored files"
}

__rec_cheat_fd() {
  __rec_cheat_section "fd" \
    "fd PATTERN                find files matching pattern" \
    "fd -e py                  only .py files" \
    "fd -H -E .git             include hidden, exclude .git" \
    "fd -t d 'name'            directories only" \
    "fd 'foo' -x rm            run 'rm' on each match" \
    "fd 'foo' -X mv -t dest/   batch-pipe matches to one mv call"
}

__rec_cheat_eza() {
  __rec_cheat_section "eza" \
    "eza                       basic listing" \
    "eza -l --git              long format + git status" \
    "eza --tree --level=2      two-level tree" \
    "eza -l --sort=size        largest files first" \
    "eza -la --total-size      recursive size per dir" \
    "eza -l --no-permissions   compact long format"
}

__rec_cheat_bat() {
  __rec_cheat_section "bat" \
    "bat file                  paged + highlighted" \
    "bat -p file               plain output (no decorations)" \
    "bat -l json file          force a specific syntax" \
    "bat --diff a.txt b.txt    colorful diff" \
    "tail -f log | bat -p -l log    live colorized tail"
}

__rec_cheat_fzf() {
  __rec_cheat_section "fzf" \
    "Ctrl+T                    pick files into the current command" \
    "Alt+C                     cd into a subdirectory via fzf" \
    "Ctrl+R                    history search (overridden by atuin if installed)" \
    "git branch | fzf          interactive single-line picker" \
    "fzf --multi               select multiple entries with TAB"
}

__rec_cheat_atuin() {
  __rec_cheat_section "atuin" \
    "Ctrl+R                    fuzzy through ALL history (with metadata)" \
    "atuin search 'pattern'    non-interactive search" \
    "atuin search --cwd .      history from this directory only" \
    "atuin stats               top commands and frequency" \
    "atuin sync                push/pull to/from your atuin server"
}

__rec_cheat_btop() {
  __rec_cheat_section "btop" \
    "btop                      open the interactive monitor" \
    "F2                        settings panel" \
    "F4                        filter processes by name" \
    "+/- on a process          adjust niceness" \
    "p                         pause updates"
}

__rec_cheat_ncdu() {
  __rec_cheat_section "ncdu" \
    "ncdu .                    interactive du in the current dir" \
    "ncdu -x /                 stay on one filesystem (don't cross mounts)" \
    "ncdu --exclude .git       skip a path" \
    "d                         delete the highlighted entry (with confirm)" \
    "?                         show all key bindings"
}

__rec_cheat_help() {
  cat <<'EOF'
rec cheat — top-5 recipes per installed CLI tool

Usage:
  rec cheat                Every tool you have installed.
  rec cheat <tool>         Just that tool. Names: rg, fd, eza, bat, fzf,
                           atuin, btop, ncdu.
EOF
}

__rec_cheat_dispatch() {
  _rce_cmd="${1:-all}"
  [ $# -gt 0 ] && shift
  case "$_rce_cmd" in
    help | --help | -h)
      __rec_cheat_help
      return 0
      ;;
    all)
      local any=0
      rec_have rg && {
        __rec_cheat_rg
        any=1
      }
      rec_have fd && {
        __rec_cheat_fd
        any=1
      }
      rec_have eza && {
        __rec_cheat_eza
        any=1
      }
      rec_have bat && {
        __rec_cheat_bat
        any=1
      }
      rec_have fzf && {
        __rec_cheat_fzf
        any=1
      }
      rec_have atuin && {
        __rec_cheat_atuin
        any=1
      }
      rec_have btop && {
        __rec_cheat_btop
        any=1
      }
      rec_have ncdu && {
        __rec_cheat_ncdu
        any=1
      }
      if [ "$any" -eq 0 ]; then
        rec_ui_info 'no modern CLI tools installed (run: rec doctor)'
      fi
      ;;
    rg | ripgrep)
      if rec_have rg; then
        __rec_cheat_rg
      else
        rec_ui_err 'ripgrep is not installed'
        return 1
      fi
      ;;
    fd)
      if rec_have fd; then
        __rec_cheat_fd
      else
        rec_ui_err 'fd is not installed'
        return 1
      fi
      ;;
    eza | ls)
      if rec_have eza; then
        __rec_cheat_eza
      else
        rec_ui_err 'eza is not installed'
        return 1
      fi
      ;;
    bat | cat)
      if rec_have bat; then
        __rec_cheat_bat
      else
        rec_ui_err 'bat is not installed'
        return 1
      fi
      ;;
    fzf)
      if rec_have fzf; then
        __rec_cheat_fzf
      else
        rec_ui_err 'fzf is not installed'
        return 1
      fi
      ;;
    atuin)
      if rec_have atuin; then
        __rec_cheat_atuin
      else
        rec_ui_err 'atuin is not installed'
        return 1
      fi
      ;;
    btop | top)
      if rec_have btop; then
        __rec_cheat_btop
      else
        rec_ui_err 'btop is not installed'
        return 1
      fi
      ;;
    ncdu | du)
      if rec_have ncdu; then
        __rec_cheat_ncdu
      else
        rec_ui_err 'ncdu is not installed'
        return 1
      fi
      ;;
    *)
      rec_ui_err "rec cheat: unknown tool \"$_rce_cmd\""
      printf '\n' >&2
      __rec_cheat_help >&2
      return 2
      ;;
  esac
}
