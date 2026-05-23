# rec-shell

Modern, modular **bash & zsh** configuration — one codebase for both shells,
installed into a directory and loaded with a single line, with a ddev-style
"new version available" notification and a one-command update.

```
⬆ rec-shell 1.3.0 available — run: rec update
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
  when a newer release exists. Updates are always explicit (`rec update`).
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

Then restart your shell (or `exec $SHELL -l`) and run `rec doctor`.

Installer flags: `--user` (default), `--system`, `--unattended`, `--no-omp`,
`--dir DIR`, `--ref REF`. Overrides: `REC_SHELL_REPO_URL`, `REC_SHELL_REF`,
`REC_SHELL_DIR`.

> The prompt uses [oh-my-posh](https://ohmyposh.dev) with the bundled `recweb`
> theme; the installer offers to install oh-my-posh if it is missing.

## Commands

`rec <command>` (alias: `rec-shell`):

| Command | What it does |
| --- | --- |
| `update` | Update to the latest released tag (`git pull`), then reload |
| `check` | Check now whether a newer version exists |
| `version` | Show installed version, commit and shell/OS |
| `reload` | Re-source rec-shell in the current shell |
| `doctor` | Diagnose the installation |
| `git <command>` | Git helpers: `sync`, `push`, `release`, `init` (see below) |
| `enable` / `disable <module>` | Toggle a module |
| `uninstall` | Remove rec-shell (`--purge` also removes config) |

## What you get

Prompt (oh-my-posh + per-host color), history tuning, colorized aliases and
navigation shortcuts, completion, archive `extract`, `mkcd`, SSH `hosts` /
`open_hosts`, **DDEV smart commands** (`php`/`composer`/`npm`/`artisan`/… run in
the container when you're inside a ddev project, on the host otherwise — only
when `ddev` is installed), and optional integrations (nvm, pnpm, zoxide, …).
See `modules/`. Git helpers live under `rec git` (below).

## Git

Git helpers are grouped under `rec git`:

| Command | What it does |
| --- | --- |
| `rec git sync [--force]` | Update the current repo with the latest code from `origin` (fetch + fast-forward). Refuses on local changes; `--force` discards them and hard-resets to origin. |
| `rec git push [...]` | Stage everything, commit, and push to the upstream |
| `rec git release [...]` | Create the next semver tag (`vX.Y.Z`) and push it |
| `rec git init --url=<url>` | Initialize a new repo and push it to GitHub |

`rec git sync` is made for deploys — pull the newest code onto a server with one
command. Run `rec git <command> --help` for options.

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

Drop `modules/<name>.sh` — it loads automatically. Modules load alphabetically;
add a numeric `NN-` prefix only if you need to force load order (e.g.
`30-foo.sh` loads before any unprefixed module). Disable a module with
`REC_DISABLED_MODULES="<name>"` (the `NN-` prefix, if any, is not part of the
name). Available at load time: `$REC_SHELL_DIR`, `$REC_SHELL_NAME`
(`zsh`|`bash`), `$REC_OS` (`mac`|`linux`). See `templates/module.template`.

## Development

```sh
shfmt -d -i 2 -ci -bn rec-shell.sh install.sh uninstall.sh lib modules scripts
shellcheck rec-shell.sh install.sh uninstall.sh lib/*.sh modules/*.sh scripts/*.sh
bats test/                 # runs in bash AND zsh
```

`lib/*.sh` and `uninstall.sh` are POSIX sh (`# shellcheck shell=sh`); the loader,
`modules/*.sh`, `install.sh` and `scripts/*.sh` are bash. CI runs all of the above.

### Releasing

Run the release script from the dev repo — it bumps `VERSION`, commits, tags and
pushes in one step:

```sh
scripts/release.sh --patch    # 1.0.0 -> 1.0.1   (also --minor, --major, --v=X.Y.Z)
scripts/release.sh -n         # preview, change nothing
```

This is separate from `rec git release` (generic, tag-only): the script owns the
`VERSION` file that drives the update notification. CI's `version-guard` fails
the tag build if `VERSION` ≠ the tag, so the runtime version, the tag and the
proxy's `/VERSION` stay in sync.

## License

MIT — see [LICENSE](LICENSE).
