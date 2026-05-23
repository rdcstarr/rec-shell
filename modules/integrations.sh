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
