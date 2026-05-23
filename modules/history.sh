# shellcheck shell=bash
# shellcheck disable=SC2034 # these are shell history vars, consumed by the shell
#
# History configuration. The mechanisms genuinely differ between shells.

HISTSIZE=999999

if [ "$REC_SHELL_NAME" = zsh ]; then
  SAVEHIST=999999
  HISTFILE="$HOME/.zsh_history"
  setopt HIST_IGNORE_DUPS
  setopt HIST_IGNORE_SPACE
  setopt APPEND_HISTORY
  setopt SHARE_HISTORY
  setopt CHECK_JOBS
else
  HISTFILESIZE=999999
  HISTCONTROL=ignoreboth
  shopt -s histappend
  shopt -s checkwinsize
fi
