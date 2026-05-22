# shellcheck shell=bash
#
# Aliases. Shared across shells; OS-specific bits key off $REC_OS, not the shell.

# Colorized output (macOS ls uses -G, GNU ls uses --color)
if [ "$REC_OS" = mac ]; then
  alias ls='ls -G'
else
  alias ls='ls --color=auto'
fi
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'

# ls shortcuts
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

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

# Git is available as a command group: `rec git sync|push|release|init`.
