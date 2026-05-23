# shellcheck shell=bash
#
# SSH host helpers. ONE portable implementation for bash and zsh: awk owns the
# whole job (comment stripping, Include-following, Host extraction), so none of
# the shell-specific array/regex constructs from the old prototype are needed.
#
#   hosts          # list Host names from ~/.ssh/config (and Included files)
#   hosts foo      # filter by substring (case-insensitive)
#   open_hosts     # edit ~/.ssh/config ($EDITOR, or `code` with --code)

__ssh_list_hosts() {
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
    BEGIN {
      queue[++qn] = home "/.ssh/config"
      for (qi = 1; qi <= qn; qi++) {
        file = queue[qi]
        if (file in done) continue
        done[file] = 1
        while ((getline line < file) > 0) {
          line = strip(line)
          if (line ~ /^[[:space:]]*[Ii]nclude[[:space:]]+/) {
            n = split(line, a, /[[:space:]]+/)
            for (i = 2; i <= n; i++) if (a[i] != "") add_file(a[i])
          } else if (line ~ /^[[:space:]]*[Hh]ost[[:space:]]+/) {
            n = split(line, a, /[[:space:]]+/)
            for (i = 2; i <= n; i++)
              if (a[i] !~ /[*?]/ && !(a[i] in seen_host)) {
                seen_host[a[i]] = 1
                print a[i]
              }
          }
        }
        close(file)
      }
    }
  ' | sort -u
}

hosts() {
  if [ -n "${1:-}" ]; then
    __ssh_list_hosts | grep -i -- "$1"
  else
    __ssh_list_hosts
  fi
}

open_hosts() {
  mkdir -p "$HOME/.ssh"
  : >>"$HOME/.ssh/config"
  if [ "${1:-}" = "--code" ] && rec_have code; then
    code "$HOME/.ssh/config"
  else
    "${EDITOR:-nano}" "$HOME/.ssh/config"
  fi
}
alias open-hosts='open_hosts'
