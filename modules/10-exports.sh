# shellcheck shell=bash
#
# Environment variables (identical across shells).

export EDITOR='nano'
export VISUAL='nano'
export PAGER='less'

# Colorized less. $Du/$Db are less' termcap color codes, not shell variables,
# so single quotes (no expansion) are intentional here.
# shellcheck disable=SC2016
export LESS='-R --use-color -Dd+r$Du+b'
