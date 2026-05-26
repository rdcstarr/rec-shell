# shellcheck shell=bash
# shellcheck disable=SC1091 # integration scripts live outside this repo
#
# Optional third-party integrations. Each is guarded so a missing tool is
# silently skipped. Disable the whole module with:
#   REC_DISABLED_MODULES="integrations"

# macOS path_helper (assembles PATH from /etc/paths.d)
if [ "$REC_OS" = mac ] && [ -x /usr/libexec/path_helper ]; then
  eval "$(/usr/libexec/path_helper -s)"
fi

# ~/.local/bin on PATH (idempotent)
if [ -d "$HOME/.local/bin" ]; then
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) PATH="$HOME/.local/bin:$PATH" ;;
  esac
fi

# npm global binaries on PATH (idempotent; added unconditionally so it works
# even before the prefix dir is first created)
case ":$PATH:" in
  *":$HOME/.npm-global/bin:"*) ;;
  *) PATH="$HOME/.npm-global/bin:$PATH" ;;
esac

# pnpm — PNPM_HOME is set unconditionally so pnpm knows where to install global
# packages even before that directory exists yet.
export PNPM_HOME="$HOME/.local/share/pnpm"
case ":$PATH:" in
  *":$PNPM_HOME:"*) ;;
  *) PATH="$PNPM_HOME:$PATH" ;;
esac

# nvm (Node Version Manager)
if [ -d "$HOME/.nvm" ]; then
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  if [ "$REC_SHELL_NAME" = bash ] && [ -s "$NVM_DIR/bash_completion" ]; then
    . "$NVM_DIR/bash_completion"
  fi
fi

# zoxide (smarter cd)
if rec_have zoxide; then
  eval "$(zoxide init "$REC_SHELL_NAME")"
fi

# Hestia control panel
[ -r /etc/profile.d/hestia.sh ] && . /etc/profile.d/hestia.sh

# command-not-found handler (Debian/Ubuntu, bash)
if [ "$REC_SHELL_NAME" = bash ] && [ -x /usr/lib/command-not-found ]; then
  command_not_found_handle() {
    /usr/lib/command-not-found -- "$1"
    return $?
  }
fi

# --- modern CLI tools ------------------------------------------------------
#
# A few of the upstream installers (atuin's setup script, fzf's local clone
# install) drop binaries under $HOME/.atuin/bin or $HOME/.fzf/bin which are
# NOT on PATH by default. Prepend them when they exist so the rec_have
# checks below (and `rec doctor`, `rec install list`, …) actually see the
# tool after it's installed via `rec install` — without forcing the user
# to restart their shell.
_rec_prepend_path() {
  [ -d "$1" ] || return 0
  case ":$PATH:" in
    *":$1:"*) ;;
    *) PATH="$1:$PATH" ;;
  esac
}
_rec_prepend_path "$HOME/.atuin/bin"
_rec_prepend_path "$HOME/.fzf/bin"
export PATH
unset -f _rec_prepend_path

# fzf shell hooks (Ctrl+T files, Alt+C directories). Sourced BEFORE atuin so
# atuin's Ctrl+R binding wins at the end.
if rec_have fzf; then
  _fzf_shell=""
  if [ -d /opt/homebrew/opt/fzf/shell ]; then
    _fzf_shell=/opt/homebrew/opt/fzf/shell
  elif [ -d /usr/local/opt/fzf/shell ]; then
    _fzf_shell=/usr/local/opt/fzf/shell
  elif [ -d /usr/share/doc/fzf/examples ]; then
    _fzf_shell=/usr/share/doc/fzf/examples
  elif [ -d /usr/share/fzf ]; then
    _fzf_shell=/usr/share/fzf
  fi
  if [ -n "$_fzf_shell" ]; then
    case "$REC_SHELL_NAME" in
      bash)
        [ -r "$_fzf_shell/key-bindings.bash" ] && . "$_fzf_shell/key-bindings.bash"
        [ -r "$_fzf_shell/completion.bash" ] && . "$_fzf_shell/completion.bash"
        ;;
      zsh)
        [ -r "$_fzf_shell/key-bindings.zsh" ] && . "$_fzf_shell/key-bindings.zsh"
        [ -r "$_fzf_shell/completion.zsh" ] && . "$_fzf_shell/completion.zsh"
        ;;
    esac
  fi
  unset _fzf_shell
fi

# atuin (rich shell history — takes over Ctrl+R; sourced AFTER fzf).
if rec_have atuin; then
  case "$REC_SHELL_NAME" in
    bash) eval "$(atuin init bash)" ;;
    zsh) eval "$(atuin init zsh)" ;;
  esac
fi

# Debian/Ubuntu: bat/fd binaries are sometimes installed as batcat/fdfind.
if ! rec_have bat && rec_have batcat; then alias bat=batcat; fi
if ! rec_have fd && rec_have fdfind; then alias fd=fdfind; fi

# zsh-only: autosuggestions, then syntax-highlighting (which MUST be last).
if [ "$REC_SHELL_NAME" = zsh ]; then
  [ -r "$REC_SHELL_DIR/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh" ] \
    && . "$REC_SHELL_DIR/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh"
  [ -r "$REC_SHELL_DIR/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ] \
    && . "$REC_SHELL_DIR/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
fi

# Optional: one random rec tip on shell startup. Opt-in only.
if [ "${REC_TIP_ON_START:-0}" = 1 ] && [ -r "$REC_SHELL_DIR/lib/cli-tips.sh" ]; then
  . "$REC_SHELL_DIR/lib/cli-tips.sh"
  command -v __rec_tip_random >/dev/null 2>&1 && __rec_tip_random
fi
