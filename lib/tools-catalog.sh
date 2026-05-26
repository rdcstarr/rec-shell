# shellcheck shell=sh
#
# lib/tools-catalog.sh — single source of truth for the modern CLI tools
# rec-shell can install. Used by:
#   - `rec doctor`        (lib/cli.sh:__rec_doctor_tools) for the ✓/✗ list
#   - `rec install`       (lib/cli-install.sh) for the multiselect
#   - install.sh          (when the file is available post-clone)
#   - `rec update`        for the soft "N tools available" notice
#
# POSIX sh only — must load identically in bash and zsh.

# rec_tools_catalog -> one record per line, fields separated by '|':
#   name|bin|kind|packages|description
#
#   kind ∈ pm | special-fzf | special-atuin | zsh-plugin
#   packages is CSV (tried in order via install.sh's pm_install); for
#     zsh-plugin entries it's the git clone URL.
rec_tools_catalog() {
  cat <<'EOF'
fzf|fzf|special-fzf|fzf|fuzzy file/dir finder + key bindings
atuin|atuin|special-atuin|atuin|magical shell history (Ctrl+R)
eza|eza|pm|eza|modern ls replacement
bat|bat|pm|bat|cat with syntax highlighting
fd|fd|pm|fd,fd-find|modern find replacement
ripgrep|rg|pm|ripgrep|fast modern grep
btop|btop|pm|btop|interactive system monitor
ncdu|ncdu|pm|ncdu|interactive disk usage
whois|whois|pm|whois|whois lookups (rec whois)
dig|dig|pm|bind,dnsutils,bind-utils,bind-tools|DNS lookups (rec dns)
zsh-autosuggestions||zsh-plugin|https://github.com/zsh-users/zsh-autosuggestions.git|fish-like autosuggestions
zsh-syntax-highlighting||zsh-plugin|https://github.com/zsh-users/zsh-syntax-highlighting.git|command-line syntax colors
EOF
}

# rec_tools_field NAME FIELD-INDEX -> echo the requested field for tool NAME.
# Fields are 1=name 2=bin 3=kind 4=packages 5=description. Empty on miss.
rec_tools_field() {
  rec_tools_catalog | awk -F'|' -v n="$1" -v f="$2" '$1 == n { print $f; exit }'
}

# rec_tools_present NAME -> 0 if installed, 1 otherwise.
# For zsh-plugin entries we check for the main plugin file under
# $REC_SHELL_DIR/plugins/<name>/<name>.zsh; for everything else we check
# for the catalogued binary on PATH (with the usual Debian aliases).
rec_tools_present() {
  _rtp_name="$1"
  _rtp_kind="$(rec_tools_field "$_rtp_name" 3)"
  if [ -z "$_rtp_kind" ]; then
    unset _rtp_name _rtp_kind
    return 1
  fi
  case "$_rtp_kind" in
    zsh-plugin)
      if [ -r "$REC_SHELL_DIR/plugins/$_rtp_name/$_rtp_name.zsh" ]; then
        unset _rtp_name _rtp_kind
        return 0
      fi
      unset _rtp_name _rtp_kind
      return 1
      ;;
    *)
      _rtp_bin="$(rec_tools_field "$_rtp_name" 2)"
      if [ -z "$_rtp_bin" ]; then
        unset _rtp_name _rtp_kind _rtp_bin
        return 1
      fi
      if rec_have "$_rtp_bin"; then
        unset _rtp_name _rtp_kind _rtp_bin
        return 0
      fi
      # Debian aliases match the doctor's existing special cases.
      case "$_rtp_name" in
        bat)
          if rec_have batcat; then
            unset _rtp_name _rtp_kind _rtp_bin
            return 0
          fi
          ;;
        fd)
          if rec_have fdfind; then
            unset _rtp_name _rtp_kind _rtp_bin
            return 0
          fi
          ;;
      esac
      unset _rtp_name _rtp_kind _rtp_bin
      return 1
      ;;
  esac
}

# rec_tools_missing -> emit (one per line) the names of catalog tools that
# are NOT installed on this host.
rec_tools_missing() {
  rec_tools_catalog | awk -F'|' '{ print $1 }' | while IFS= read -r _rtm_n; do
    [ -z "$_rtm_n" ] && continue
    rec_tools_present "$_rtm_n" || printf '%s\n' "$_rtm_n"
  done
}

# rec_tools_count_missing -> print the count of missing tools.
rec_tools_count_missing() {
  rec_tools_missing | awk 'NF' | wc -l | awk '{print $1}'
}
