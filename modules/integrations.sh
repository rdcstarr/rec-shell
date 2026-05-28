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
# fzf's user-mode clone install drops binaries under $HOME/.fzf/bin which is
# NOT on PATH by default. Prepend it when it exists so the rec_have check
# below (and `rec doctor`, `rec install list`, …) actually sees fzf after
# `rec install fzf` — without forcing the user to restart their shell.
if [ -d "$HOME/.fzf/bin" ]; then
  case ":$PATH:" in
    *":$HOME/.fzf/bin:"*) ;;
    *) PATH="$HOME/.fzf/bin:$PATH" ;;
  esac
  export PATH
fi

# fzf shell hooks: Ctrl+T (files), Alt+C (cd), Ctrl+R (history search).
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
  elif [ -d "$HOME/.fzf/shell" ]; then
    _fzf_shell="$HOME/.fzf/shell"
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

# Debian/Ubuntu: bat/fd binaries are sometimes installed as batcat/fdfind.
if ! rec_have bat && rec_have batcat; then alias bat=batcat; fi
if ! rec_have fd && rec_have fdfind; then alias fd=fdfind; fi

# Shell-specific line-editor enhancements.
#   zsh -> zsh-autosuggestions + zsh-syntax-highlighting (sourced in that order
#          because syntax-highlighting must come last)
#   bash -> ble.sh (single drop-in that ships both features)
case "$REC_SHELL_NAME" in
  zsh)
    [ -r "$REC_SHELL_DIR/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh" ] \
      && . "$REC_SHELL_DIR/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh"
    [ -r "$REC_SHELL_DIR/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ] \
      && . "$REC_SHELL_DIR/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
    ;;
  bash)
    # ble.sh's recommended bootstrap is two-phase: source with --noattach so
    # it just defines its functions (bleopt, ble-bind, …), then call
    # ble-attach AFTER any module that touches PS1/PROMPT_COMMAND has run.
    # install.sh's pre-stub at the top of /etc/bash.bashrc absorbs the
    # bleopt calls oh-my-posh's bash init emits before this loader runs.
    #
    # Skip re-sourcing on `rec reload`. When ble.sh is sourced again while
    # already attached, it prints "[ble: reload] / [ble: detached]" and
    # leaves the tty in a state that needs `stty sane`. BLE_VERSION is
    # ble.sh's "I'm loaded" marker — keep the existing instance.
    if [ -z "${BLE_VERSION:-}" ] && [ -r "$HOME/.local/share/blesh/ble.sh" ]; then
      . "$HOME/.local/share/blesh/ble.sh" --noattach
      if [ -n "${BLE_VERSION:-}" ]; then
        PROMPT_COMMAND="ble-attach${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
        # Permanently block oh-my-posh's transient-prompt → ble.sh
        # integration. oh-my-posh init.NNN.sh ends with:
        #   bleopt prompt_ps1_transient=always
        #   bleopt prompt_ps1_final='$(oh-my-posh print transient ...)'
        # Our bundled `recweb` theme has no `transient_prompt` block,
        # so `print transient` returns empty and ble.sh swaps every
        # prior prompt to that empty string — the OS/host/path header
        # vanishes after each command.
        #
        # /etc/bash.bashrc's oh-my-posh init runs BEFORE us and hits
        # our bleopt no-op pre-stub (harmless). But users often have
        # the same `eval "$(oh-my-posh init bash …)"` in ~/.bashrc,
        # which runs AFTER rec-shell loads — by then bleopt is real
        # and the assignment sticks. A one-shot reset can't catch that.
        #
        # Wrap the real bleopt so prompt_ps1_transient= and
        # prompt_ps1_final= assignments are silently dropped from any
        # source (init script, manual call, whatever), while every
        # other bleopt operation passes through unchanged.
        __rec_blepm_orig="$(declare -f bleopt 2>/dev/null)"
        if [ -n "$__rec_blepm_orig" ]; then
          # Copy bleopt to __rec_real_bleopt by renaming the
          # `bleopt ()` header on the first line of declare -f's output.
          eval "$(printf '%s\n' "$__rec_blepm_orig" | sed '1s/^bleopt /__rec_real_bleopt /')"
          bleopt() {
            case "${1:-}" in
              prompt_ps1_transient=*) return 0 ;;
              prompt_ps1_final=*)     return 0 ;;
            esac
            __rec_real_bleopt "$@"
          }
          # Reset whatever was already set before the wrapper installed.
          __rec_real_bleopt prompt_ps1_transient= prompt_ps1_final= 2>/dev/null || true
        fi
        unset __rec_blepm_orig
      fi
    fi
    ;;
esac

# Optional: one random rec tip on shell startup. Opt-in only.
if [ "${REC_TIP_ON_START:-0}" = 1 ] && [ -r "$REC_SHELL_DIR/lib/cli-tips.sh" ]; then
  . "$REC_SHELL_DIR/lib/cli-tips.sh"
  command -v __rec_tip_random >/dev/null 2>&1 && __rec_tip_random
fi
