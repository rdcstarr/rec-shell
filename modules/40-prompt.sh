# shellcheck shell=bash
#
# Prompt: oh-my-posh with the vendored "recweb" theme.
#
# IMPORTANT: OMP_HOST_BG must be exported BEFORE `oh-my-posh init` runs — the
# theme reads it from the environment at render time. (The old prototype set it
# afterwards and only worked by accident on the next redraw.)

# Derive a stable background color from the hostname.
rec_omp_host_bg() {
  _rohb_host="$(hostname 2>/dev/null || printf '%s' "${HOSTNAME:-localhost}")"

  # Palette as positional params so indexing is 1-based in BOTH bash and zsh.
  set -- \
    "#E49595" "#E4AD95" "#E4C395" "#E4D795" "#D7E495" \
    "#B6E495" "#95E495" "#95E4B6" "#95E4D7" "#95D1E4" \
    "#95B6E4" "#959CE4" "#A995E4" "#C395E4" "#DE95E4" \
    "#E495D1" "#E495BD" "#E495A9" "#95E4CA" "#E4CA95"
  _rohb_n=$#

  if rec_have sha256sum; then
    _rohb_hex="$(printf '%s' "$_rohb_host" | sha256sum | cut -c1-8)"
  elif rec_have shasum; then
    _rohb_hex="$(printf '%s' "$_rohb_host" | shasum -a 256 | cut -c1-8)"
  else
    return 0
  fi

  # 16#NN is understood by both bash and zsh arithmetic.
  _rohb_idx=$((16#$_rohb_hex % _rohb_n + 1))
  shift "$((_rohb_idx - 1))"
  OMP_HOST_BG="$1"
  export OMP_HOST_BG
}

# Initialize the prompt. Color first, then init.
rec_prompt_init() {
  _rpi_omp="${REC_OMP_BIN:-oh-my-posh}"
  rec_have "$_rpi_omp" || return 0
  # oh-my-posh's generated bash init requires bash >= 4 (uses `[[ -v ]]`). Skip
  # on older bash (e.g. macOS system bash 3.2) to avoid syntax-error noise; zsh
  # and modern bash (Linux servers) are unaffected.
  if [ "$REC_SHELL_NAME" = bash ] && [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
    return 0
  fi
  _rpi_theme="${REC_THEME:-$REC_SHELL_DIR/themes/recweb.omp.json}"
  [ -r "$_rpi_theme" ] || return 0

  rec_omp_host_bg
  # $REC_SHELL_NAME is exactly "zsh" or "bash" — the arg oh-my-posh expects.
  eval "$("$_rpi_omp" init "$REC_SHELL_NAME" --config "$_rpi_theme")"
}

rec_prompt_init
