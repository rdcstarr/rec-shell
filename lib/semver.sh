# shellcheck shell=sh
#
# lib/semver.sh — portable semantic-version comparison.
#
# rec_semver_gt A B
#   Returns 0 (true) when A is strictly newer than B, else 1.
#   Tolerates a leading "v" and ignores any -prerelease / +build suffix,
#   so the update banner only ever fires on stable release bumps.
#
# Fields are extracted with pure parameter expansion (no word-splitting, no
# `set --`, no IFS games): zsh does not word-split unquoted variables the way
# bash/sh do, so anything relying on `set -- $var` would silently misbehave in
# zsh. Integer math is used (not `sort -V`) because BSD and GNU `sort -V`
# disagree on prerelease ordering, and a string compare ranks 1.9 above 1.10.

rec_semver_gt() {
  _rsg_a="${1#v}"
  _rsg_b="${2#v}"
  _rsg_a="${_rsg_a%%[-+]*}" # drop -prerelease / +build
  _rsg_b="${_rsg_b%%[-+]*}"

  # Split "MAJOR.MINOR.PATCH" via parameter expansion only.
  _rsg_a1="${_rsg_a%%.*}"
  _rsg_ar="${_rsg_a#*.}"
  [ "$_rsg_ar" = "$_rsg_a" ] && _rsg_ar=""
  _rsg_a2="${_rsg_ar%%.*}"
  _rsg_ar2="${_rsg_ar#*.}"
  [ "$_rsg_ar2" = "$_rsg_ar" ] && _rsg_ar2=""
  _rsg_a3="${_rsg_ar2%%.*}"

  _rsg_b1="${_rsg_b%%.*}"
  _rsg_br="${_rsg_b#*.}"
  [ "$_rsg_br" = "$_rsg_b" ] && _rsg_br=""
  _rsg_b2="${_rsg_br%%.*}"
  _rsg_br2="${_rsg_br#*.}"
  [ "$_rsg_br2" = "$_rsg_br" ] && _rsg_br2=""
  _rsg_b3="${_rsg_br2%%.*}"

  # Empty or non-numeric fields (missing or malformed) count as 0.
  case "$_rsg_a1" in '' | *[!0-9]*) _rsg_a1=0 ;; esac
  case "$_rsg_a2" in '' | *[!0-9]*) _rsg_a2=0 ;; esac
  case "$_rsg_a3" in '' | *[!0-9]*) _rsg_a3=0 ;; esac
  case "$_rsg_b1" in '' | *[!0-9]*) _rsg_b1=0 ;; esac
  case "$_rsg_b2" in '' | *[!0-9]*) _rsg_b2=0 ;; esac
  case "$_rsg_b3" in '' | *[!0-9]*) _rsg_b3=0 ;; esac

  [ "$_rsg_a1" -gt "$_rsg_b1" ] && return 0
  [ "$_rsg_a1" -lt "$_rsg_b1" ] && return 1
  [ "$_rsg_a2" -gt "$_rsg_b2" ] && return 0
  [ "$_rsg_a2" -lt "$_rsg_b2" ] && return 1
  [ "$_rsg_a3" -gt "$_rsg_b3" ] && return 0
  return 1
}
