# Modern CLI tools + discovery

## Context

The user uses rec-shell daily and wants the project to install (and integrate) a curated set of modern CLI tools so they don't have to bootstrap every new machine by hand. The list: **fzf, atuin, eza, bat, fd, ripgrep, btop, ncdu, zsh-autosuggestions, zsh-syntax-highlighting**. Default behavior is "install everything"; users can subset via flags. The user also wants a low-friction reminder mechanism so they actually *use* these tools instead of falling back to old habits — concretely, `rec tips` (one tip per call) and `rec cheat` (full cheatsheet for installed tools). An "AI agent" was considered and rejected as a privacy/maintenance overcommitment for a self-contained shell config.

## Resolved conflicts

| Conflict | Resolution |
|---|---|
| fzf and atuin both bind `Ctrl+R` | Install both. atuin owns `Ctrl+R` (richer history). fzf retains `Ctrl+T` (files) and `Alt+C` (directories). |
| eza vs existing `ls`/`ll`/`la`/`l` aliases in `modules/aliases.sh:5-23` | When eza is present, override aliases with eza equivalents. Without eza, keep current ls aliases. |
| bat as `cat` | Do not alias `cat=bat`. `bat` stays itself. Aliasing `cat` would break scripts depending on raw line-buffered output. |
| btop vs `rec sys top` | Not a conflict. `rec sys top` is scriptable non-interactive (`ps`-based); btop is a TUI. Both ship. |
| ncdu vs `rec sys disk` | Not a conflict. `rec sys disk` is non-interactive; ncdu is a TUI. Both ship. |
| zsh-autosuggestions / zsh-syntax-highlighting on bash | Skip on bash. No popular equivalent (ble.sh is too heavyweight). `rec doctor` shows a one-line note for bash users. |

## Installer changes (`install.sh`)

### New flags

- `--tools=fzf,eza,bat` — install only the listed tools (allowlist).
- `--without=atuin,btop` — install all tools except the listed ones (denylist).
- `--no-tools` — skip every tool from this list (existing `--no-omp` / `--no-zoxide` behavior, generalized).
- `--unattended` (existing) — never prompt; install what selection permits.

`--tools` and `--without` are mutually exclusive; passing both is a usage error (exit 2). Default (no flag) installs all.

### Per-tool function pattern

For each tool, an `ensure_<tool>` function with this shape (mirrors `ensure_omp` at `install.sh:248-273` and `ensure_zoxide` at `install.sh:275-297`):

1. Short-circuit when the tool's command is already on `PATH` (`rec_have <bin>` check using the installer's local copy of `rec_have`-equivalent logic).
2. Check the selection rules — skip if `--tools` allowlist excludes it or `--without` denylist includes it.
3. When not `--unattended`, prompt: "Install <tool>?".
4. Install via package manager, in this priority: brew (macOS) → apt-get → dnf → pacman → apk. Each PM call is fenced behind `command -v <pm>`.
5. Fallback to a static binary from the upstream GitHub release when no PM matches (all tools on the list ship static binaries). For non-root user-mode, install to `$HOME/.local/bin` and warn if that directory is not on `PATH`.

### Package mapping

| Tool | macOS (brew) | Debian/Ubuntu (apt) | Fedora/RHEL (dnf) | Arch (pacman) | Alpine (apk) | Static binary |
|---|---|---|---|---|---|---|
| fzf | `fzf` | `fzf` | `fzf` | `fzf` | `fzf` | git clone + `install` script |
| atuin | `atuin` | upstream installer | upstream installer | upstream installer | upstream installer | yes (binary) |
| eza | `eza` | `eza` (24.04+) / cargo / static | `eza` | `eza` | `eza` | yes |
| bat | `bat` | `bat` (binary may be `batcat`; alias when needed) | `bat` | `bat` | `bat` | yes |
| fd | `fd` | `fd-find` (binary is `fdfind`; alias when needed) | `fd-find` | `fd` | `fd` | yes |
| ripgrep | `ripgrep` | `ripgrep` | `ripgrep` | `ripgrep` | `ripgrep` | yes |
| btop | `btop` | `btop` | `btop` | `btop` | `btop` | yes |
| ncdu | `ncdu` | `ncdu` | `ncdu` | `ncdu` | `ncdu` | yes |

For `bat` on Debian/Ubuntu: the binary may be installed as `batcat`. The installer prints a note suggesting `alias bat=batcat`; rec-shell's `modules/integrations.sh` does this automatically (see below).

For `fd` on Debian/Ubuntu: same pattern — binary may be `fdfind`. Auto-aliased to `fd` when only `fdfind` is on PATH.

### zsh plugin install

zsh-autosuggestions and zsh-syntax-highlighting are git repos, not packages. They install via shallow clone into `$REC_SHELL_DIR/plugins/<plugin-name>/`. On update (`rec update`), the existing `git pull` on `$REC_SHELL_DIR` does not touch the plugin dirs; a separate `git -C plugins/<name> pull` happens as part of `rec update` (extension to `lib/cli.sh:__rec_cmd_update`).

For `--system` installs, the plugin dirs live alongside the rest of rec-shell in `/opt/rec-shell/plugins/`, owned by root and world-readable.

## Module changes

### `modules/aliases.sh` — eza-aware ls aliases

Inject at the top of the file, before the existing ls aliases:

```sh
if rec_have eza; then
  alias ls='eza --group-directories-first --icons=auto'
  alias ll='eza -l --git --group-directories-first --icons=auto'
  alias la='eza -la --git --group-directories-first --icons=auto'
  alias l='eza --git --group-directories-first --icons=auto'
else
  # existing ls aliases stay verbatim here
fi
```

This keeps the file's character: feature-flag detection, no hard dependency. Existing `grep`/`fgrep`/`egrep`/`mkdir`/`df`/`du` aliases stay unchanged.

### `modules/integrations.sh` — shell hooks

Append to the existing module (after the current nvm/pnpm/zoxide/path_helper blocks). **Ordering matters**: fzf shell hooks are sourced FIRST (they re-bind Ctrl+R to fzf's history), then atuin init runs LAST so its Ctrl+R binding wins. This is the order atuin's own README recommends.

```sh
# fzf shell hooks (Ctrl+T files, Alt+C directories). Sourced BEFORE atuin so
# atuin's Ctrl+R binding overrides fzf's at the end.
if rec_have fzf; then
  # macOS brew install path
  if [ -d /opt/homebrew/opt/fzf/shell ]; then _fzf_shell=/opt/homebrew/opt/fzf/shell
  elif [ -d /usr/local/opt/fzf/shell ]; then _fzf_shell=/usr/local/opt/fzf/shell
  # Debian/Ubuntu
  elif [ -d /usr/share/doc/fzf/examples ]; then _fzf_shell=/usr/share/doc/fzf/examples
  fi
  if [ -n "${_fzf_shell:-}" ]; then
    case "$REC_SHELL_NAME" in
      bash) [ -r "$_fzf_shell/key-bindings.bash" ] && . "$_fzf_shell/key-bindings.bash"
            [ -r "$_fzf_shell/completion.bash"  ] && . "$_fzf_shell/completion.bash"  ;;
      zsh)  [ -r "$_fzf_shell/key-bindings.zsh"  ] && . "$_fzf_shell/key-bindings.zsh"
            [ -r "$_fzf_shell/completion.zsh"   ] && . "$_fzf_shell/completion.zsh"   ;;
    esac
    unset _fzf_shell
  fi
fi

# atuin — sourced AFTER fzf so it takes back Ctrl+R for richer history search.
if rec_have atuin; then
  case "$REC_SHELL_NAME" in
    bash) eval "$(atuin init bash)" ;;
    zsh)  eval "$(atuin init zsh)"  ;;
  esac
fi

# Debian/Ubuntu: bat/fd binaries are sometimes named batcat/fdfind.
if ! rec_have bat && rec_have batcat; then alias bat=batcat; fi
if ! rec_have fd  && rec_have fdfind; then alias fd=fdfind;  fi

# zsh-only plugins. Syntax-highlighting MUST source last per upstream docs.
if [ "$REC_SHELL_NAME" = zsh ]; then
  [ -r "$REC_SHELL_DIR/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh" ] \
    && . "$REC_SHELL_DIR/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh"
  [ -r "$REC_SHELL_DIR/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ] \
    && . "$REC_SHELL_DIR/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
fi

# Optional: print one rec tip on startup. Off by default.
if [ "${REC_TIP_ON_START:-0}" = 1 ] && command -v __rec_tip_random >/dev/null 2>&1; then
  __rec_tip_random
fi
```

### Doctor extension (`lib/cli.sh:__rec_cmd_doctor`)

Add a "tools" section after the existing checks, listing each tool with ✓/✗ and a single-line hint when missing:

```
tools:
  ✓ fzf
  ✗ atuin       (install: rec doctor; not on path)
  ✓ eza
  ...
```

For bash, also print: `note: zsh-autosuggestions and zsh-syntax-highlighting are zsh-only`.

## New rec subcommands — `lib/cli-tips.sh`

One file exposes two dispatchers: `__rec_tips_dispatch` and `__rec_cheat_dispatch`. Wired into `lib/cli.sh` as two lazy-loaded subcommands (`rec tips`, `rec cheat`), following the existing pattern from `__rec_cmd_port`, `__rec_cmd_sys`, etc. (`lib/cli.sh:352-430`).

### Tips database

A single bash array literal at the top of `lib/cli-tips.sh`, e.g.:

```sh
REC_TIPS=(
  "rg|rg 'pattern' -t py — search only Python files"
  "rg|rg --hidden 'pattern' — include dotfiles"
  "fd|fd '\\.rs$' src — find Rust files under src/"
  "fd|fd -e jpg -X mogrify -resize 800x — pipe matches into a command"
  "eza|eza --tree --level=2 — visual two-level tree"
  "eza|eza -l --sort=size — largest files first"
  "bat|bat -p file.json | jq — bat as syntax-highlighting pager"
  "bat|bat --diff old.txt new.txt — colorful diff"
  "atuin|Ctrl+R — fuzzy through ALL history (with timestamps, exit codes)"
  "atuin|atuin search --cwd . — recall commands run in this directory"
  "fzf|Ctrl+T — fuzzy pick a file into the current command"
  "fzf|Alt+C — fuzzy cd to any subdirectory"
  "btop|btop — full-screen interactive top with mouse + gradient bars"
  "ncdu|ncdu -x / — interactive disk usage on root filesystem"
  ...
)
```

Each entry is `<tool-key>|<tip-text>`. Filtering by installed tools = `rec_have <tool-key>` check on the first field.

### Behavior

| Command | Behavior |
|---|---|
| `rec tips` | Print one random tip (filtered to installed tools). |
| `rec tips next` | Cycle: read index from `$REC_CACHE_DIR/tips-index`, print Nth filtered tip, increment. |
| `rec tips all` | Print every tip applicable to this install, grouped by tool. |
| `rec tips help` | Usage. |
| `rec cheat` | Cheatsheet sections for every installed tool from the list. |
| `rec cheat <tool>` | Just that tool's section (`rec cheat rg`, `rec cheat eza`). |
| `rec cheat help` | Usage. |

Cheat sections live inline in `lib/cli-tips.sh` as functions: `__rec_cheat_rg`, `__rec_cheat_eza`, etc. Each prints ~5-8 high-value command lines. The dispatcher picks the right ones based on what's installed.

### Optional startup hint

Off by default. Users opt in via `REC_TIP_ON_START=1` in `~/.rec-shell.local`. When set, `modules/integrations.sh` calls `__rec_tip_random` (a tiny standalone function defined directly in `lib/cli-tips.sh` and re-imported via inline source on first use — same lazy pattern, but the hook only sources when the env var is set, so startup cost stays zero for non-users).

## Uninstall

No changes required. The plugin dirs live inside `$REC_SHELL_DIR` (which gets `rm -rf`-ed). System packages installed via brew/apt are NOT removed — they may be used by other software, and uninstalling rec-shell shouldn't make a user lose `bat` from the rest of their system.

## Testing

- Each new function (`ensure_<tool>`) is covered by a tiny bats test that stubs the package managers and asserts the chosen install path. New test files: `test/install-tools.bats`, `test/tips.bats`, `test/cheat.bats`.
- The existing test suite (153 tests) continues to pass.
- Manual smoke test on macOS dev box + a Linux container (Debian + Fedora) before release.

## Verification

```sh
# Lint
shfmt -d -i 2 -ci -bn install.sh lib/cli-tips.sh modules/aliases.sh modules/integrations.sh
shellcheck install.sh lib/cli-tips.sh modules/aliases.sh modules/integrations.sh

# Tests
bats test/

# Manual
curl -fsSL https://rec-shell.recwebnetwork.com/install.sh | bash -s -- --user --unattended
exec $SHELL -l
rec doctor       # shows tools section with ✓/✗
rec tips         # one random tip
rec tips all
rec cheat eza
ls               # if eza installed, runs eza
# Ctrl+R         # atuin opens
# Ctrl+T         # fzf opens
# Alt+C          # fzf cd opens

# Selection flags
curl ... | bash -s -- --user --tools=fzf,eza,bat,rg --unattended
curl ... | bash -s -- --user --without=atuin,btop --unattended
curl ... | bash -s -- --user --no-tools --unattended
```

After everything passes:
- `VERSION` `1.2.0` → `1.4.0` (minor — installer adds tools + 2 new commands). Bundles also the prior unfinished install.sh UX fixes and the 6 subcommands shipped earlier today.
- Single commit per logical group; release via `scripts/release.sh --minor`.

## Out of scope (explicit non-goals)

- AI agent / LLM integration. Rejected for privacy, billing, dependency creep, and maintenance burden. Users with Claude Code or `gh copilot` already have far better tools.
- `alias cat=bat`. Aliasing core tools breaks scripts.
- bash autosuggestions / syntax highlighting via ble.sh. Too heavy and not popular enough to maintain.
- Uninstalling system packages on `rec uninstall`. Other software may depend on them.
- Cross-distro auto-detection beyond apt/dnf/pacman/apk. Static binaries cover the long tail.
