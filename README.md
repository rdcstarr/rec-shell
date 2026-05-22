# rec-shell

Modern, modular **bash & zsh** configuration — one codebase for both shells,
installed into a directory and loaded with a single line, with a ddev-style
"new version available" notification and a one-command update.

```
⬆ rec-shell 1.3.0 available — run: rec-shell update
```

## Why

A previous prototype was two ~740-line rc files (one per shell) copied across
many servers — duplicated, invasive to update (it overwrote everyone's rc), and
with no way to learn that a newer version existed. `rec-shell` replaces that:

- **One codebase, both shells.** Shared POSIX code; shell-specific bits branch
  on `$REC_SHELL_NAME`. No more bash/zsh copy-paste.
- **Non-invasive install.** Your `~/.zshrc` / `~/.bashrc` keep a single guarded
  line; updates never touch your personal rc or local customizations.
- **Update notifications.** A daily, non-blocking check prints a one-line banner
  when a newer release exists. Updates are always explicit (`rec-shell update`).
- **Extensible.** Add a file to `modules/` and it loads automatically.

## Install

Per user (no root):

```sh
curl -fsSL https://rec-shell.recwebnetwork.com/install | bash
```

System-wide for every user on a server (adds the loader to `/etc` rc files):

```sh
curl -fsSL https://rec-shell.recwebnetwork.com/install | sudo bash -s -- --system
```

Then restart your shell (or `exec $SHELL -l`) and run `rec-shell doctor`.

Installer flags: `--user` (default), `--system`, `--unattended`, `--no-omp`,
`--dir DIR`, `--ref REF`. Overrides: `REC_SHELL_REPO_URL`, `REC_SHELL_REF`,
`REC_SHELL_DIR`.

> The prompt uses [oh-my-posh](https://ohmyposh.dev) with the bundled `recweb`
> theme; the installer offers to install oh-my-posh if it is missing.

## Commands

`rec-shell <command>` (alias: `rec`):

| Command | What it does |
| --- | --- |
| `update` | Update to the latest released tag (`git pull`), then reload |
| `check` | Check now whether a newer version exists |
| `version` | Show installed version, commit and shell/OS |
| `reload` | Re-source rec-shell in the current shell |
| `doctor` | Diagnose the installation |
| `enable` / `disable <module>` | Toggle a module |
| `uninstall` | Remove rec-shell (`--purge` also removes config) |

## What you get

Prompt (oh-my-posh + per-host color), history tuning, colorized aliases and
navigation shortcuts, completion, archive `extract`, `mkcd`, the git helpers
`git_release` / `git_push` / `git_init_repo` (aliased `release` / `push` /
`init-repo`), SSH `hosts` / `open_hosts`, and optional integrations (nvm,
zoxide, …). See `modules/`.

## Configuration

Edit `${XDG_CONFIG_HOME:-$HOME/.config}/rec-shell/config` (created on demand,
never overwritten by updates — see `templates/config.template`):

```sh
REC_DISABLED_MODULES="ssh integrations"   # disable modules by name
REC_UPDATE_CHECK="daily"                   # daily | weekly | hourly | never
```

Personal aliases/functions go in `~/.rec-shell.local` (sourced last, so it wins).
Existing `~/.zsh_aliases` / `~/.bash_aliases` are still sourced for back-compat.

## Add a module

Drop `modules/NN-<name>.sh` (numeric prefix sets load order) — it loads
automatically; disable it with `REC_DISABLED_MODULES="<name>"`. Available at
load time: `$REC_SHELL_DIR`, `$REC_SHELL_NAME` (`zsh`|`bash`), `$REC_OS`
(`mac`|`linux`). See `templates/module.template`.

## Development

```sh
shfmt -d -i 2 -ci -bn rec-shell.sh install.sh uninstall.sh lib modules
shellcheck rec-shell.sh install.sh uninstall.sh lib/*.sh modules/*.sh
bats test/                 # runs in bash AND zsh
```

`lib/*.sh` and `uninstall.sh` are POSIX sh (`# shellcheck shell=sh`); the loader,
`modules/*.sh` and `install.sh` are bash. CI runs all of the above.

### Releasing

1. Bump `VERSION` (e.g. `1.2.0`) and commit.
2. Tag it: `git_release --v=1.2.0` (or `release`), which pushes `v1.2.0`.

CI's `version-guard` fails the tag build if `VERSION` ≠ the tag, keeping the
runtime version, the tag and the proxy's `/VERSION` in sync.

## License

MIT — see [LICENSE](LICENSE).
