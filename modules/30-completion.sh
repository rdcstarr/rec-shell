# shellcheck shell=bash
# shellcheck disable=SC1091 # completion scripts live outside this repo
#
# Shell completion initialization.

if [ "$REC_SHELL_NAME" = zsh ]; then
  autoload -Uz compinit
  compinit
else
  if [ -r /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -r /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi
