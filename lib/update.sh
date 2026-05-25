# shellcheck shell=sh
#
# lib/update.sh — ddev-style "new version available" notification.
#
# Design rule: shell startup performs ZERO network and never blocks the prompt.
# At startup we only read a tiny cache, compare once, maybe print one line, and
# maybe launch a fully-detached background refresh for next time.
#
# Depends on: rec_installed_version, rec_have (lib/core.sh), rec_semver_gt
# (lib/semver.sh), and REC_CACHE_DIR / REC_CACHE_FILE (lib/core.sh).

# rec_update_interval -> seconds between background checks.
rec_update_interval() {
  if [ -n "${REC_UPDATE_INTERVAL:-}" ]; then
    printf '%s' "$REC_UPDATE_INTERVAL"
    return 0
  fi
  case "${REC_UPDATE_CHECK:-daily}" in
    hourly) printf '%s' 3600 ;;
    weekly) printf '%s' 604800 ;;
    *) printf '%s' 86400 ;;
  esac
}

# rec_update_fetch_latest -> print the latest published version, or fail.
# Tries the proxy first, then GitHub raw. Rejects anything that is not a bare
# dotted-number version, so an HTML/captive-portal error page can never be
# mistaken for a release.
rec_update_fetch_latest() {
  _ruf_primary="${REC_VERSION_URL:-https://rec-shell.recwebnetwork.com/VERSION}"
  _ruf_fallback="${REC_VERSION_URL_FALLBACK-https://raw.githubusercontent.com/rdcstarr/rec-shell/main/VERSION}"
  for _ruf_url in "$_ruf_primary" "$_ruf_fallback"; do
    [ -n "$_ruf_url" ] || continue
    _ruf_out="$(curl -fsSL --connect-timeout 2 --max-time 3 "$_ruf_url" 2>/dev/null)" || _ruf_out=""
    _ruf_out="$(printf '%s' "$_ruf_out" | head -n1 | tr -d '\r')"
    _ruf_out="${_ruf_out#v}"
    case "$_ruf_out" in
      '' | *[!0-9.]*) continue ;;
      *)
        printf '%s' "$_ruf_out"
        return 0
        ;;
    esac
  done
  return 1
}

# rec_update_refresh EPOCH -> fetch the latest version and write the cache
# atomically. On fetch failure, keep the previously known version but still
# bump the timestamp (so a down server is not re-hit on every new shell).
rec_update_refresh() {
  _rur_now="$1"
  command mkdir -p "$REC_CACHE_DIR" 2>/dev/null || return 0

  _rur_latest="$(rec_update_fetch_latest)" || _rur_latest=""
  if [ -z "$_rur_latest" ] && [ -r "$REC_CACHE_FILE" ]; then
    {
      read -r _rur_skip
      read -r _rur_latest
    } <"$REC_CACHE_FILE" 2>/dev/null || _rur_latest=""
  fi

  if printf '%s\n%s\n' "$_rur_now" "$_rur_latest" >"$REC_CACHE_FILE.tmp.$$" 2>/dev/null; then
    mv -f "$REC_CACHE_FILE.tmp.$$" "$REC_CACHE_FILE" 2>/dev/null || rm -f "$REC_CACHE_FILE.tmp.$$" 2>/dev/null
  fi
}

# rec_update_banner VERSION -> one-line nudge, on stderr so it never pollutes
# command substitution that captures stdout. Uses the UI toolkit when present
# (colors auto-off when stderr is not a TTY); falls back to plain text on a
# partial install so the "<version> available" hint always shows.
rec_update_banner() {
  if ! command -v __rec_ui_emit >/dev/null 2>&1; then
    printf 'rec-shell %s available — run: rec update\n' "$1" >&2
    return
  fi
  {
    __rec_ui_emit 2 "$REC_UI_S_YELLOW" "rec-shell $1 available"
    printf ' %s ' "$REC_UI_G_ARROW"
    __rec_ui_emit 2 "$REC_UI_S_DIM" 'run:'
    __rec_ui_emit 2 "$REC_UI_S_BOLD" ' rec update'
    printf '\n'
  } >&2
}

# rec_update_startup -> called once per interactive shell by the loader.
rec_update_startup() {
  case "${REC_UPDATE_CHECK:-daily}" in
    never | off | 0 | false | no) return 0 ;;
  esac
  rec_have curl || return 0

  _rus_installed="$(rec_installed_version 2>/dev/null)" || return 0
  [ -n "$_rus_installed" ] || return 0

  _rus_epoch=0
  _rus_latest=""
  if [ -r "$REC_CACHE_FILE" ]; then
    {
      read -r _rus_epoch
      read -r _rus_latest
    } <"$REC_CACHE_FILE" 2>/dev/null || :
    case "$_rus_epoch" in '' | *[!0-9]*) _rus_epoch=0 ;; esac
  fi

  # Banner straight from cache (no network) when a newer release is known.
  if [ -n "$_rus_latest" ] && rec_semver_gt "$_rus_latest" "$_rus_installed"; then
    rec_update_banner "$_rus_latest"
  fi

  # Throttled, fully-detached refresh for next time. `( … & )` produces no
  # job-control output in interactive bash or zsh; </dev/null avoids SIGTTIN;
  # the curl timeouts mean an offline box can never stall the prompt.
  _rus_now="$(date +%s 2>/dev/null)" || return 0
  case "$_rus_now" in '' | *[!0-9]*) return 0 ;; esac
  if [ "$((_rus_now - _rus_epoch))" -ge "$(rec_update_interval)" ]; then
    (rec_update_refresh "$_rus_now" >/dev/null 2>&1 </dev/null &)
  fi
}
