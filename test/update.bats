#!/usr/bin/env bats
#
# Unit tests for lib/update.sh — interval mapping, version fetch parsing,
# and atomic cache write. Network is avoided by pointing the fetch at a
# local file:// URL and clearing the fallback.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  REC_TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$REC_TMP"
}

# --- rec_update_interval ---------------------------------------------------

@test "interval defaults to daily (86400)" {
  run sh -c ". '$REPO_ROOT/lib/update.sh'; rec_update_interval"
  [ "$output" = "86400" ]
}

@test "interval weekly is 604800" {
  run sh -c "REC_UPDATE_CHECK=weekly; . '$REPO_ROOT/lib/update.sh'; rec_update_interval"
  [ "$output" = "604800" ]
}

@test "interval hourly is 3600" {
  run sh -c "REC_UPDATE_CHECK=hourly; . '$REPO_ROOT/lib/update.sh'; rec_update_interval"
  [ "$output" = "3600" ]
}

@test "explicit REC_UPDATE_INTERVAL overrides the named cadence" {
  run sh -c "REC_UPDATE_CHECK=weekly REC_UPDATE_INTERVAL=42; . '$REPO_ROOT/lib/update.sh'; rec_update_interval"
  [ "$output" = "42" ]
}

# --- rec_update_fetch_latest -----------------------------------------------

@test "fetch reads a clean version from the primary URL" {
  printf '1.2.3\n' >"$REC_TMP/VERSION"
  run sh -c "REC_VERSION_URL='file://$REC_TMP/VERSION' REC_VERSION_URL_FALLBACK='' . '$REPO_ROOT/lib/update.sh'; rec_update_fetch_latest"
  [ "$status" -eq 0 ]
  [ "$output" = "1.2.3" ]
}

@test "fetch strips a leading v" {
  printf 'v2.0.0\n' >"$REC_TMP/VERSION"
  run sh -c "REC_VERSION_URL='file://$REC_TMP/VERSION' REC_VERSION_URL_FALLBACK='' . '$REPO_ROOT/lib/update.sh'; rec_update_fetch_latest"
  [ "$output" = "2.0.0" ]
}

@test "fetch rejects a non-version body (e.g. an HTML error page)" {
  printf '<html>504 Gateway Timeout</html>\n' >"$REC_TMP/VERSION"
  run sh -c "REC_VERSION_URL='file://$REC_TMP/VERSION' REC_VERSION_URL_FALLBACK='' . '$REPO_ROOT/lib/update.sh'; rec_update_fetch_latest"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# --- rec_update_refresh (atomic cache write) -------------------------------

@test "refresh writes timestamp + latest version to the cache" {
  printf '1.5.0\n' >"$REC_TMP/VERSION"
  run sh -c "REC_VERSION_URL='file://$REC_TMP/VERSION' REC_VERSION_URL_FALLBACK='' REC_CACHE_DIR='$REC_TMP/c' REC_CACHE_FILE='$REC_TMP/c/update'; . '$REPO_ROOT/lib/update.sh'; rec_update_refresh 1700000000; cat '$REC_TMP/c/update'"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "1700000000" ]
  [ "$(printf '%s\n' "$output" | sed -n 2p)" = "1.5.0" ]
}

@test "refresh keeps the previous version but bumps the timestamp on fetch failure" {
  mkdir -p "$REC_TMP/c"
  printf '1000\n9.9.9\n' >"$REC_TMP/c/update"
  run sh -c "REC_VERSION_URL='file://$REC_TMP/does-not-exist' REC_VERSION_URL_FALLBACK='' REC_CACHE_DIR='$REC_TMP/c' REC_CACHE_FILE='$REC_TMP/c/update'; . '$REPO_ROOT/lib/update.sh'; rec_update_refresh 2000000000; cat '$REC_TMP/c/update'"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "2000000000" ]
  [ "$(printf '%s\n' "$output" | sed -n 2p)" = "9.9.9" ]
}
