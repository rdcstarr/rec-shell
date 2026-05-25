# shellcheck shell=bash
#
# lib/cli-ssh.sh — the `rec ssh` command group: an interactive picker over the
# hosts in ~/.ssh/config, with favorites and frecency (most-accessed) sorting.
# Lazy-loaded by lib/cli.sh on the first `rec ssh ...`. Runs under bash and zsh.
#
# Self-contained: it does NOT depend on the (user-disableable) modules/ssh.sh.
# Hosts live in ~/.ssh/config (source of truth); favorite + access state lives
# in $REC_CONFIG_DIR/ssh-stats (outside the checkout, survives updates).

# === dispatch =============================================================

__rec_ssh_dispatch() {
  if [ $# -eq 0 ]; then
    __rec_ssh_picker
    return $?
  fi
  local cmd="$1"
  case "$cmd" in
    add)
      shift
      __rec_ssh_add "$@"
      ;;
    fav)
      shift
      __rec_ssh_fav "$@"
      ;;
    edit)
      shift
      __rec_ssh_edit "$@"
      ;;
    list)
      shift
      __rec_ssh_list_plain
      ;;
    help | --help | -h) __rec_ssh_help ;;
    -*)
      rec_ui_err "rec ssh: unknown option \"$cmd\""
      return 2
      ;;
    *)
      shift
      __rec_ssh_bump "$cmd"
      __rec_ssh_connect "$cmd" "$@"
      ;;
  esac
}

__rec_ssh_help() {
  cat <<'EOF'
rec ssh — SSH host manager

Usage: rec ssh [command]

Commands:
  (no arg)        Interactive picker (up/down, enter connect, f favorite, a add)
  <alias> [args]  Connect to a host (ssh <alias>); records usage for sorting
  add [...]       Add a host to ~/.ssh/config (--alias= --host= --user= --port= --key=)
  fav [alias]     Toggle a favorite (no arg: pick favorites interactively)
  edit [--code]   Open ~/.ssh/config in your editor (or VS Code with --code)
  list            List hosts (favorites first, then most-accessed)
  help            Show this help
EOF
}

# === host enumeration =====================================================

# __rec_ssh_parse_config -> TSV "alias \t host \t user \t port \t identityfile"
# for every non-wildcard Host in ~/.ssh/config (following Include).
__rec_ssh_parse_config() {
  [ -r "$HOME/.ssh/config" ] || return 0
  awk -v home="$HOME" '
    function add_file(f,   g, cmd) {
      if (f ~ /^~\//)      f = home substr(f, 2)
      else if (f !~ /^\//) f = home "/.ssh/" f
      cmd = "ls -1d " f " 2>/dev/null"
      while ((cmd | getline g) > 0)
        if (!(g in seen_file)) { seen_file[g] = 1; queue[++qn] = g }
      close(cmd)
    }
    function strip(line) {
      sub(/\r$/, "", line)
      sub(/^[[:space:]]*#.*/, "", line)
      sub(/[[:space:]]+#.*/, "", line)
      return line
    }
    function flush(   i) {
      for (i = 1; i <= ca; i++)
        if (!(cur[i] in seen_host)) {
          seen_host[cur[i]] = 1
          print cur[i], hn, usr, port, idf
        }
      ca = 0
    }
    BEGIN {
      OFS = "\t"
      queue[++qn] = home "/.ssh/config"
      for (qi = 1; qi <= qn; qi++) {
        file = queue[qi]
        if (file in done) continue
        done[file] = 1
        while ((getline line < file) > 0) {
          line = strip(line)
          sub(/^[[:space:]]+/, "", line)
          if (line == "") continue
          key = line
          sub(/[[:space:]=].*$/, "", key)
          lkey = tolower(key)
          value = line
          sub(/^[^[:space:]=]+[[:space:]=]+/, "", value)
          if (lkey == "include") {
            n = split(value, a, /[[:space:]]+/)
            for (i = 1; i <= n; i++) if (a[i] != "") add_file(a[i])
          } else if (lkey == "host") {
            flush()
            hn = ""; usr = ""; port = ""; idf = ""
            n = split(value, a, /[[:space:]]+/)
            for (i = 1; i <= n; i++)
              if (a[i] != "" && a[i] !~ /[*?!]/) cur[++ca] = a[i]
          } else if (lkey == "match") {
            flush()
            hn = ""; usr = ""; port = ""; idf = ""
          } else if (ca > 0) {
            if (lkey == "hostname") hn = value
            else if (lkey == "user") usr = value
            else if (lkey == "port") port = value
            else if (lkey == "identityfile") idf = value
          }
        }
        close(file)
        flush()
      }
    }
  '
}

# __rec_ssh_fmt_target HOST USER PORT [ALIAS] -> "user@host:port" (sensible omits)
__rec_ssh_fmt_target() {
  local host="$1" user="$2" port="$3" name="${4:-}" out
  [ -n "$host" ] || host="$name"
  out="$host"
  [ -n "$user" ] && out="$user@$out"
  if [ -n "$port" ] && [ "$port" != "22" ]; then out="$out:$port"; fi
  printf '%s' "$out"
}

# === favorites + frecency store ===========================================
# $REC_CONFIG_DIR/ssh-stats : TSV "alias \t fav(0|1) \t count \t last_epoch".

__rec_ssh_stats_file() {
  command mkdir -p "$REC_CONFIG_DIR" 2>/dev/null
  printf '%s/ssh-stats' "$REC_CONFIG_DIR"
}

# __rec_ssh_stats_get ALIAS -> "fav count last" (0 0 0 when unknown)
__rec_ssh_stats_get() {
  local f
  f="$(__rec_ssh_stats_file)"
  if [ -r "$f" ]; then
    awk -F'\t' -v a="$1" '$1==a {print $2, $3, $4; ok=1} END {if (!ok) print "0 0 0"}' "$f"
  else
    printf '0 0 0\n'
  fi
}

# __rec_ssh_stats_put ALIAS FAV COUNT LAST -> upsert the row atomically.
__rec_ssh_stats_put() {
  local f tmp a="$1" fav="$2" count="$3" last="$4"
  f="$(__rec_ssh_stats_file)"
  tmp="$f.tmp.$$"
  {
    if [ -r "$f" ]; then awk -F'\t' -v a="$a" '$1!=a' "$f"; fi
    printf '%s\t%s\t%s\t%s\n' "$a" "$fav" "$count" "$last"
  } >"$tmp" 2>/dev/null
  if [ -f "$tmp" ]; then
    mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  fi
}

# __rec_ssh_bump ALIAS -> count++, last=now.
__rec_ssh_bump() {
  local a="$1" fav count last
  read -r fav count last <<EOF
$(__rec_ssh_stats_get "$a")
EOF
  count=$((count + 1))
  last="$(date +%s 2>/dev/null || printf '0')"
  __rec_ssh_stats_put "$a" "$fav" "$count" "$last"
}

# __rec_ssh_favtoggle ALIAS -> flip fav; echoes "on"/"off".
__rec_ssh_favtoggle() {
  local a="$1" fav count last
  read -r fav count last <<EOF
$(__rec_ssh_stats_get "$a")
EOF
  if [ "$fav" = "1" ]; then fav=0; else fav=1; fi
  __rec_ssh_stats_put "$a" "$fav" "$count" "$last"
  if [ "$fav" = "1" ]; then printf 'on'; else printf 'off'; fi
}

# __rec_ssh_favset ALIAS 0|1 -> force fav state.
__rec_ssh_favset() {
  local a="$1" want="$2" fav count last
  read -r fav count last <<EOF
$(__rec_ssh_stats_get "$a")
EOF
  __rec_ssh_stats_put "$a" "$want" "$count" "$last"
}

# __rec_ssh_enumerate_sorted -> display TSV "alias \t fav \t target", favorites
# first, then frecency desc, then alpha. The target (user@host:port) is built in
# awk so every field is non-empty (a tab IFS read collapses empty fields). Counts
# are NEVER emitted.
__rec_ssh_enumerate_sorted() {
  local f now tab
  f="$(__rec_ssh_stats_file)"
  now="$(date +%s 2>/dev/null || printf '0')"
  tab="$(printf '\t')"
  __rec_ssh_parse_config | awk -F'\t' -v OFS='\t' -v now="$now" -v statsfile="$f" '
    function frecency(count, last,   age, w) {
      if (count == 0) return 0
      if (last == 0) return count * 0.25
      age = now - last
      if (age < 3600) w = 4
      else if (age < 86400) w = 2
      else if (age < 604800) w = 0.5
      else w = 0.25
      return count * w
    }
    BEGIN {
      while ((getline s < statsfile) > 0) {
        m = split(s, p, "\t")
        if (m >= 4) { fav[p[1]] = p[2]; cnt[p[1]] = p[3]; lst[p[1]] = p[4] }
      }
      close(statsfile)
    }
    {
      a = $1
      fv = (a in fav) ? fav[a] : 0
      sc = frecency((a in cnt) ? cnt[a] : 0, (a in lst) ? lst[a] : 0)
      t = ($2 != "") ? $2 : a
      if ($3 != "") t = $3 "@" t
      if ($4 != "" && $4 != "22") t = t ":" $4
      printf "%s\t%.4f\t%s\t%s\t%s\n", fv, sc, a, fv, t
    }
  ' | LC_ALL=C sort -t"$tab" -k1,1nr -k2,2nr -k3,3 | cut -f3-
}

# __rec_ssh_list_plain -> non-interactive listing (favorites first). No counts.
__rec_ssh_list_plain() {
  local tab star name fav target
  tab="$(printf '\t')"
  if [ "${REC_UI_UTF:-no}" = "yes" ]; then star='★'; else star='*'; fi
  __rec_ssh_enumerate_sorted | while IFS="$tab" read -r name fav target; do
    [ -n "$name" ] || continue
    if [ "$fav" = "1" ]; then
      printf '%s %s  %s\n' "$star" "$name" "$target"
    else
      printf '  %s  %s\n' "$name" "$target"
    fi
  done
}

# === connect / edit =======================================================

__rec_ssh_connect() {
  local name="$1"
  shift
  if ! rec_have ssh; then
    rec_ui_err 'ssh not found on PATH'
    return 127
  fi
  rec_ui_step "Connecting to $name..."
  command ssh "$name" "$@"
}

__rec_ssh_edit() {
  command mkdir -p "$HOME/.ssh"
  : >>"$HOME/.ssh/config"
  if [ "${1:-}" = "--code" ] && rec_have code; then
    code "$HOME/.ssh/config"
  else
    "${EDITOR:-nano}" "$HOME/.ssh/config"
  fi
}

# === add ==================================================================

__rec_ssh_add() {
  local name='' host='' user='' port='' key='' interactive=1 arg
  for arg in "$@"; do
    case "$arg" in
      --alias=*)
        name="${arg#*=}"
        interactive=0
        ;;
      --host=*)
        host="${arg#*=}"
        interactive=0
        ;;
      --user=*)
        user="${arg#*=}"
        interactive=0
        ;;
      --port=*)
        port="${arg#*=}"
        interactive=0
        ;;
      --key=*)
        key="${arg#*=}"
        interactive=0
        ;;
      -h | --help)
        printf 'Usage: rec ssh add [--alias=NAME --host=HOST --user=USER --port=N --key=PATH]\n'
        return 0
        ;;
      *)
        rec_ui_err "rec ssh add: unknown option \"$arg\""
        return 2
        ;;
    esac
  done

  if [ "$interactive" = "1" ]; then
    if ! rec_ui_interactive_load || ! __rec_ui_interactive; then
      rec_ui_err 'usage: rec ssh add --alias=NAME --host=HOST [...]'
      return 2
    fi
    name="$(rec_ui_input 'Alias (Host)')"
    host="$(rec_ui_input 'HostName' "$name")"
    user="$(rec_ui_input 'User' "${USER:-}")"
    port="$(rec_ui_input 'Port' '22')"
    key="$(rec_ui_input 'IdentityFile (optional, blank to skip)')"
  fi

  case "$name" in
    '')
      rec_ui_err 'alias is required'
      return 1
      ;;
    *[[:space:]]*)
      rec_ui_err 'alias must not contain whitespace'
      return 1
      ;;
  esac
  if __rec_ssh_parse_config | cut -f1 | grep -qx -- "$name"; then
    rec_ui_err "host \"$name\" already exists in ~/.ssh/config"
    return 1
  fi
  [ -n "$host" ] || host="$name"
  [ -n "$user" ] || user="${USER:-}"
  [ -n "$port" ] || port="22"

  command mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh" 2>/dev/null
  if [ ! -e "$HOME/.ssh/config" ]; then
    : >"$HOME/.ssh/config"
    chmod 600 "$HOME/.ssh/config" 2>/dev/null
  fi
  {
    printf '\n'
    printf 'Host %s\n' "$name"
    printf '    HostName %s\n' "$host"
    [ -n "$user" ] && printf '    User %s\n' "$user"
    printf '    Port %s\n' "$port"
    [ -n "$key" ] && printf '    IdentityFile %s\n' "$key"
  } >>"$HOME/.ssh/config"
  rec_ui_ok "Added host \"$name\" ($(__rec_ssh_fmt_target "$host" "$user" "$port" "$name"))."

  if rec_ui_interactive_load && rec_ui_confirm "Connect to $name now?" no; then
    __rec_ssh_bump "$name"
    __rec_ssh_connect "$name"
  fi
}

# === favorites command ====================================================

__rec_ssh_fav() {
  local name="${1:-}" state all a
  if [ -n "$name" ]; then
    if ! __rec_ssh_parse_config | cut -f1 | grep -qx -- "$name"; then
      rec_ui_err "host \"$name\" not found in ~/.ssh/config"
      return 1
    fi
    state="$(__rec_ssh_favtoggle "$name")"
    rec_ui_ok "Favorite $state for \"$name\"."
    return 0
  fi

  if ! rec_ui_interactive_load || ! __rec_ui_interactive; then
    rec_ui_err 'usage: rec ssh fav <alias>'
    return 2
  fi
  all="$(__rec_ssh_parse_config | cut -f1)"
  if [ -z "$all" ]; then
    rec_ui_info 'No hosts in ~/.ssh/config.'
    return 0
  fi
  if [ -n "${ZSH_VERSION:-}" ]; then
    setopt local_options sh_word_split 2>/dev/null
  fi
  # shellcheck disable=SC2086 # intentional word-split of the newline-separated list
  rec_ui_multiselect 'Select favorites (replaces current set)' $all >/dev/null
  # shellcheck disable=SC2086
  for a in $all; do
    case " ${REC_UI_REPLY:-} " in
      *" $a "*) __rec_ssh_favset "$a" 1 ;;
      *) __rec_ssh_favset "$a" 0 ;;
    esac
  done
  rec_ui_ok 'Favorites updated.'
}

# === interactive picker ===================================================

# A dedicated raw-key picker (rec_ui_select can't bind the `f` key). Reuses the
# toolkit primitives: draws to stderr, hides/restores the cursor, redraws by
# moving up. Non-TTY: falls back to the plain list (never hangs).
__rec_ssh_picker() {
  if ! rec_ui_interactive_load || ! __rec_ui_interactive; then
    __rec_ssh_list_plain
    return 0
  fi

  local rows n sel first total i line name fav target star tab
  tab="$(printf '\t')"
  if [ "${REC_UI_UTF:-no}" = "yes" ]; then star='★'; else star='*'; fi
  rows="$(__rec_ssh_enumerate_sorted)"
  if [ -z "$rows" ]; then n=0; else n="$(printf '%s\n' "$rows" | wc -l | tr -d ' ')"; fi
  total=$((n + 1))
  sel=1
  first=1

  {
    printf '\033[?25l'
    while :; do
      if [ "$first" = "1" ]; then first=0; else printf '\033[%dA' "$total"; fi
      i=1
      while [ "$i" -le "$n" ]; do
        line="$(printf '%s\n' "$rows" | sed -n "${i}p")"
        IFS="$tab" read -r name fav target <<EOF
$line
EOF
        printf '\r\033[2K'
        __rec_ui_emit 1 "$REC_UI_S_CYAN" "$REC_UI_G_V"
        if [ "$i" = "$sel" ]; then
          printf ' '
          [ "$fav" = "1" ] && __rec_ui_emit 1 "$REC_UI_S_YELLOW" "$star "
          __rec_ui_emit 1 "$REC_UI_S_CYAN" "$REC_UI_G_GT $name"
        else
          printf '   '
          [ "$fav" = "1" ] && __rec_ui_emit 1 "$REC_UI_S_YELLOW" "$star "
          printf '%s' "$name"
        fi
        __rec_ui_emit 1 "$REC_UI_S_DIM" "  $target"
        printf '\n'
        i=$((i + 1))
      done
      printf '\r\033[2K'
      __rec_ui_emit 1 "$REC_UI_S_CYAN" "$REC_UI_G_V"
      if [ "$sel" = "$total" ]; then
        __rec_ui_emit 1 "$REC_UI_S_CYAN" " $REC_UI_G_GT Add new connection"
      else
        printf '   '
        __rec_ui_emit 1 "$REC_UI_S_DIM" 'Add new connection'
      fi
      printf '\n'

      case "$(__rec_ui_readkey)" in
        up)
          sel=$((sel - 1))
          [ "$sel" -lt 1 ] && sel="$total"
          ;;
        down)
          sel=$((sel + 1))
          [ "$sel" -gt "$total" ] && sel=1
          ;;
        f | F)
          if [ "$sel" -le "$n" ]; then
            line="$(printf '%s\n' "$rows" | sed -n "${sel}p")"
            name="${line%%"$tab"*}"
            __rec_ssh_favtoggle "$name" >/dev/null
            rows="$(__rec_ssh_enumerate_sorted)"
            sel="$(printf '%s\n' "$rows" | awk -F"$tab" -v a="$name" '$1==a {print NR; exit}')"
            [ -n "$sel" ] || sel=1
          fi
          ;;
        a | A)
          sel="$total"
          break
          ;;
        enter) break ;;
        q | esc)
          printf '\033[?25h'
          return 130
          ;;
      esac
    done
    printf '\033[?25h'
  } >&2

  if [ "$sel" = "$total" ]; then
    __rec_ssh_add
    return $?
  fi
  line="$(printf '%s\n' "$rows" | sed -n "${sel}p")"
  name="${line%%"$tab"*}"
  [ -n "$name" ] || return 0
  __rec_ssh_bump "$name"
  __rec_ssh_connect "$name"
}
