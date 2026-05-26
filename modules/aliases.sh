# shellcheck shell=bash
#
# Aliases. Shared across shells; OS-specific bits key off $REC_OS, not the shell.

# ls family: prefer eza when present; fall back to coreutils ls otherwise.
if rec_have eza; then
  alias ls='eza --group-directories-first --icons=auto'
  alias ll='eza -l --git --group-directories-first --icons=auto'
  alias la='eza -la --git --group-directories-first --icons=auto'
  alias l='eza --git --group-directories-first --icons=auto'
else
  if [ "$REC_OS" = mac ]; then
    alias ls='ls -G'
  else
    alias ls='ls --color=auto'
  fi
  alias ll='ls -alF'
  alias la='ls -A'
  alias l='ls -CF'
fi
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'

# Quick navigation
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# Safer / friendlier defaults
alias mkdir='mkdir -pv'
alias df='df -h'
alias du='du -h'
if [ "$REC_OS" = mac ]; then
  alias top='top -o cpu'
else
  alias free='free -h'
  alias top='htop 2>/dev/null || top'
fi
