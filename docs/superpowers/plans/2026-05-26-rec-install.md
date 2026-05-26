# `rec install` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an interactive `rec install` command for picking modern CLI tools from a multiselect, plus a soft post-`rec update` notification when tools are missing.

**Architecture:** Extract the tool catalog (currently duplicated across `install.sh`'s `install_tools_all` and `lib/cli.sh`'s `__rec_doctor_tools`) into a shared `lib/tools-catalog.sh` sourced eagerly. `rec install` becomes a thin command that consults the catalog, runs `rec_ui_multiselect` on the missing tools, and shells out to `install.sh --tools-only --tools=<csv> --unattended` (a new flag that skips the bootstrap stages and runs only `install_tools_all`). At the tail of a successful `rec update`, the catalog is queried for missing tools; if any are missing, a single dim line is printed — never a prompt.

**Tech Stack:** POSIX sh (lib/ files), bash (install.sh, modules/), bats for tests. Reuses `rec_have`, `rec_ui_multiselect` (REC_UI_REPLY), `rec_ui_note`, the existing `pm_install` and `ensure_tool` machinery in install.sh.

---

## File Structure

**New files:**
- `lib/tools-catalog.sh` — POSIX sh. Defines `rec_tools_catalog` (emits per-tool records), `rec_tools_present <name>`, `rec_tools_missing` (emits missing names, one per line), `rec_tools_count_missing`.
- `lib/cli-install.sh` — POSIX sh. `__rec_install_dispatch`, `__rec_install_help`, `__rec_install_list`, `__rec_install_run`, `__rec_install_interactive`.
- `test/tools-catalog.bats`, `test/install.bats` — bats tests with PATH stubs.

**Modified files:**
- `rec-shell.sh` — source `lib/tools-catalog.sh` after `lib/ui.sh` (eager, like core/ui).
- `install.sh` — add `--tools-only` arg parsing + branch in the run sequence; source `lib/tools-catalog.sh` after `clone_or_update` (when available) but keep existing `ensure_*` functions untouched.
- `lib/cli.sh` — dispatch `install`, lazy-loader `__rec_cmd_install`, help row, menu entry; replace `__rec_doctor_tools` inline list with a loop over `rec_tools_catalog`; soft notification at the tail of `__rec_cmd_update`.
- `README.md` — one row for `rec install` in the commands table.

---

## Catalog Format

Each line emitted by `rec_tools_catalog` is `name|bin|kind|packages|description`:

| Field | Meaning |
|---|---|
| `name` | Canonical name (matches install.sh `--tools=` selector and `ensure_*` function). |
| `bin` | Binary used by `rec_have` to detect presence. Empty for zsh plugins. |
| `kind` | `pm` (package manager), `special-fzf`, `special-atuin`, `zsh-plugin`. |
| `packages` | CSV passed to `pm_install` (in order). For zsh-plugin: the git repo URL. |
| `description` | One-line, used by `rec install list` and the multiselect. |

The records (a single string heredoc'd inside `rec_tools_catalog`):

```
fzf|fzf|special-fzf|fzf|fuzzy file/dir finder + key bindings
atuin|atuin|special-atuin|atuin|magical shell history (Ctrl+R)
eza|eza|pm|eza|modern ls replacement
bat|bat|pm|bat|cat with syntax highlighting
fd|fd|pm|fd,fd-find|modern find replacement
ripgrep|rg|pm|ripgrep|fast modern grep
btop|btop|pm|btop|interactive system monitor
ncdu|ncdu|pm|ncdu|interactive disk usage
whois|whois|pm|whois|whois lookups (rec whois)
dig|dig|pm|bind,dnsutils,bind-utils,bind-tools|DNS lookups (rec dns)
zsh-autosuggestions||zsh-plugin|https://github.com/zsh-users/zsh-autosuggestions.git|fish-like autosuggestions
zsh-syntax-highlighting||zsh-plugin|https://github.com/zsh-users/zsh-syntax-highlighting.git|command-line syntax colors
```

---

## Task 1: lib/tools-catalog.sh

**Files:**
- Create: `lib/tools-catalog.sh`
- Test: `test/tools-catalog.bats`

- [ ] **Step 1: Write the failing tests**

Create `test/tools-catalog.bats`:

```bash
#!/usr/bin/env bats
#
# Tests for lib/tools-catalog.sh.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CAT="$REPO_ROOT/lib/tools-catalog.sh"
  T="$(mktemp -d)"
  mkdir -p "$T/bin"
}
teardown() { rm -rf "$T"; }

# Source the catalog (and its core/ui deps) in a sandboxed shell.
cat_in() {
  local shell="$1"
  shift
  run "$shell" -c "
    export HOME='$T' PATH='$T/bin:/usr/bin:/bin' REC_SHELL_DIR='$REPO_ROOT'
    REC_SHELL_NAME='$shell' REC_UI_PLAIN=1
    . '$REPO_ROOT/lib/core.sh'
    . '$REPO_ROOT/lib/ui.sh'
    . '$CAT'
    $*"
}

@test "rec_tools_catalog emits one pipe-separated record per known tool" {
  cat_in bash 'rec_tools_catalog | wc -l | awk "{print \$1}"'
  [ "$status" -eq 0 ]
  # Catalog must include at least the 12 declared tools.
  [ "$output" -ge 12 ]
}

@test "rec_tools_catalog records are well-formed (5 fields each)" {
  cat_in bash 'rec_tools_catalog | awk -F"|" "NF != 5 { print \"bad:\" \$0; exit 1 } END { print \"ok\" }"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "rec_tools_present returns 0 when the binary is on PATH" {
  printf "#!/bin/sh\nexit 0\n" >"$T/bin/eza"
  chmod +x "$T/bin/eza"
  cat_in bash 'rec_tools_present eza && echo Y || echo N'
  [[ "$output" == "Y" ]]
}

@test "rec_tools_present returns 1 when the binary is absent" {
  cat_in bash '
    rec_have() { case "$1" in eza) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
    rec_tools_present eza && echo Y || echo N'
  [[ "$output" == "N" ]]
}

@test "rec_tools_present checks the plugin file for zsh-plugin entries" {
  # zsh-autosuggestions is "present" iff its main file is readable under
  # $REC_SHELL_DIR/plugins/<name>/<name>.zsh.
  cat_in bash 'rec_tools_present zsh-autosuggestions && echo Y || echo N'
  # In this test we point REC_SHELL_DIR at the dev repo, which does not ship
  # the plugin checkout -> expect "N".
  [[ "$output" == "N" ]]
}

@test "rec_tools_missing skips installed tools, lists the rest" {
  # Stub two tools as present; the rest stay missing.
  printf "#!/bin/sh\nexit 0\n" >"$T/bin/eza"
  printf "#!/bin/sh\nexit 0\n" >"$T/bin/bat"
  chmod +x "$T/bin/eza" "$T/bin/bat"
  cat_in bash 'rec_tools_missing | sort | tr "\n" " "'
  [ "$status" -eq 0 ]
  [[ "$output" != *"eza"* ]]
  [[ "$output" != *"bat"* ]]
  [[ "$output" == *"fd"* ]]
}

@test "rec_tools_count_missing returns an integer" {
  cat_in bash 'rec_tools_count_missing'
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
}
```

- [ ] **Step 2: Run the tests, confirm they fail**

```bash
bats test/tools-catalog.bats
```

Expected: ALL fail with "command not found" or "no such file or directory" (lib/tools-catalog.sh does not exist yet).

- [ ] **Step 3: Implement lib/tools-catalog.sh**

```sh
# shellcheck shell=sh
#
# lib/tools-catalog.sh — single source of truth for the modern CLI tools
# rec-shell can install. Used by:
#   - `rec doctor`        (lib/cli.sh:__rec_doctor_tools) for the ✓/✗ list
#   - `rec install`       (lib/cli-install.sh) for the multiselect
#   - install.sh          (when the file is available post-clone)
#   - `rec update`        for the soft "N tools available" notice
#
# POSIX sh only — must load identically in bash and zsh.

# rec_tools_catalog -> one record per line, fields separated by '|':
#   name|bin|kind|packages|description
#
#   kind ∈ pm | special-fzf | special-atuin | zsh-plugin
#   packages is CSV (tried in order via install.sh's pm_install); for
#     zsh-plugin entries it's the git clone URL.
rec_tools_catalog() {
  cat <<'EOF'
fzf|fzf|special-fzf|fzf|fuzzy file/dir finder + key bindings
atuin|atuin|special-atuin|atuin|magical shell history (Ctrl+R)
eza|eza|pm|eza|modern ls replacement
bat|bat|pm|bat|cat with syntax highlighting
fd|fd|pm|fd,fd-find|modern find replacement
ripgrep|rg|pm|ripgrep|fast modern grep
btop|btop|pm|btop|interactive system monitor
ncdu|ncdu|pm|ncdu|interactive disk usage
whois|whois|pm|whois|whois lookups (rec whois)
dig|dig|pm|bind,dnsutils,bind-utils,bind-tools|DNS lookups (rec dns)
zsh-autosuggestions||zsh-plugin|https://github.com/zsh-users/zsh-autosuggestions.git|fish-like autosuggestions
zsh-syntax-highlighting||zsh-plugin|https://github.com/zsh-users/zsh-syntax-highlighting.git|command-line syntax colors
EOF
}

# rec_tools_field NAME FIELD-INDEX -> echo the requested field for tool NAME.
# Fields are 1=name 2=bin 3=kind 4=packages 5=description. Empty on miss.
rec_tools_field() {
  rec_tools_catalog | awk -F'|' -v n="$1" -v f="$2" '$1 == n { print $f; exit }'
}

# rec_tools_present NAME -> 0 if installed, 1 otherwise.
# For zsh-plugin entries we check for the main plugin file under
# $REC_SHELL_DIR/plugins/<name>/<name>.zsh; for everything else we check
# for the catalogued binary on PATH (with the usual Debian aliases).
rec_tools_present() {
  _rtp_name="$1"
  _rtp_kind="$(rec_tools_field "$_rtp_name" 3)"
  [ -z "$_rtp_kind" ] && return 1
  case "$_rtp_kind" in
    zsh-plugin)
      [ -r "$REC_SHELL_DIR/plugins/$_rtp_name/$_rtp_name.zsh" ]
      return $?
      ;;
    *)
      _rtp_bin="$(rec_tools_field "$_rtp_name" 2)"
      [ -z "$_rtp_bin" ] && return 1
      rec_have "$_rtp_bin" && return 0
      # Debian aliases match the doctor's existing special cases.
      case "$_rtp_name" in
        bat) rec_have batcat && return 0 ;;
        fd) rec_have fdfind && return 0 ;;
      esac
      return 1
      ;;
  esac
}

# rec_tools_missing -> emit (one per line) the names of catalog tools that
# are NOT installed on this host.
rec_tools_missing() {
  rec_tools_catalog | awk -F'|' '{ print $1 }' | while IFS= read -r _rtm_n; do
    [ -z "$_rtm_n" ] && continue
    rec_tools_present "$_rtm_n" || printf '%s\n' "$_rtm_n"
  done
}

# rec_tools_count_missing -> print the count of missing tools.
rec_tools_count_missing() {
  rec_tools_missing | awk 'NF' | wc -l | awk '{print $1}'
}
```

- [ ] **Step 4: Wire eager source into rec-shell.sh**

In `rec-shell.sh`, immediately after the existing `[ -r "$REC_SHELL_DIR/lib/ui.sh" ] && . "$REC_SHELL_DIR/lib/ui.sh"` line, add:

```sh
[ -r "$REC_SHELL_DIR/lib/tools-catalog.sh" ] && . "$REC_SHELL_DIR/lib/tools-catalog.sh"
```

- [ ] **Step 5: Run the tests, confirm they pass**

```bash
bats test/tools-catalog.bats
```

Expected: all 7 tests pass.

- [ ] **Step 6: Lint**

```bash
shellcheck lib/tools-catalog.sh rec-shell.sh
shfmt -d -i 2 -ci -bn lib/tools-catalog.sh rec-shell.sh
```

Expected: no output (clean).

- [ ] **Step 7: Commit**

```bash
git add lib/tools-catalog.sh test/tools-catalog.bats rec-shell.sh
git commit -m "feat(tools): lib/tools-catalog.sh — single source of truth for CLI tools"
```

---

## Task 2: refactor `__rec_doctor_tools` to use the catalog

**Files:**
- Modify: `lib/cli.sh:193-224`

- [ ] **Step 1: Update the existing doctor test (if any) to assert on catalog tools**

Look at `test/smoke.bats` and `test/ui.bats` — no doctor-specific test currently asserts the exact tool list. Add a smoke check in `test/tools-catalog.bats`:

```bash
@test "doctor exposes every tool catalogued (smoke)" {
  cat_in bash '
    . "$REPO_ROOT/lib/cli.sh"
    __rec_doctor_tools 2>&1' \
    | tr "\n" " "
  # whois and dig are new; both should appear.
  [[ "$output" == *"whois"* && "$output" == *"dig"* ]]
}
```

- [ ] **Step 2: Run, confirm fails** (the inline list happens to already include whois/dig from v1.3.0, so it MIGHT pass; if it does, skip Step 3's refactor and just confirm via Step 4 below. If you simulate by adding a hypothetical 13th tool to the catalog and assert on it, the test fails first.)

Skip-if-passes; this is a refactor task so a green test is acceptable.

- [ ] **Step 3: Replace the inline `for _rdt_t in ...` loop**

In `lib/cli.sh`, replace the body of `__rec_doctor_tools` between `rec_ui_heading "tools"` and the zsh-plugin block:

```sh
__rec_doctor_tools() {
  rec_ui_heading "tools"
  if command -v rec_tools_catalog >/dev/null 2>&1; then
    rec_tools_catalog | while IFS='|' read -r _rdt_name _rdt_bin _rdt_kind _rdt_pkgs _rdt_desc; do
      [ -z "$_rdt_name" ] && continue
      case "$_rdt_kind" in
        zsh-plugin) continue ;;  # zsh plugins reported in the dedicated block below
      esac
      if rec_tools_present "$_rdt_name"; then
        __rec_ok "$_rdt_name present"
      else
        __rec_no "$_rdt_name missing"
      fi
    done
  fi
  # zsh plugins (kept separate so they only show on zsh and use a different
  # presence check — the catalog's rec_tools_present already does the right
  # thing on both shells, but we surface them in their own block for clarity).
  if [ "$REC_SHELL_NAME" = zsh ]; then
    for _rdt_p in zsh-autosuggestions zsh-syntax-highlighting; do
      if rec_tools_present "$_rdt_p"; then
        __rec_ok "$_rdt_p present"
      else
        __rec_no "$_rdt_p missing"
      fi
    done
  else
    rec_ui_note "zsh-autosuggestions and zsh-syntax-highlighting are zsh-only"
  fi
  unset _rdt_name _rdt_bin _rdt_kind _rdt_pkgs _rdt_desc _rdt_p
}
```

- [ ] **Step 4: Run the full bats suite**

```bash
bats test/
```

Expected: 190+ tests pass (current baseline + 7 new from Task 1 = 197+, no regressions).

- [ ] **Step 5: Manually verify doctor output**

```bash
bash -c '
  export REC_SHELL_DIR="$(pwd)" REC_SHELL_NAME=bash
  . ./lib/core.sh; . ./lib/ui.sh; . ./lib/tools-catalog.sh; . ./lib/cli.sh
  __rec_doctor_tools'
```

Expected: same shape as before (one line per tool with ✓/✗), no formatting regressions.

- [ ] **Step 6: Commit**

```bash
git add lib/cli.sh test/tools-catalog.bats
git commit -m "refactor(doctor): drive __rec_doctor_tools from lib/tools-catalog.sh"
```

---

## Task 3: install.sh `--tools-only` flag

**Files:**
- Modify: `install.sh` (arg parser + run sequence)

- [ ] **Step 1: Write the failing test**

Add to `test/install.bats` (will be created in Task 4; for now we add this test there in advance):

```bash
#!/usr/bin/env bats
#
# Tests for `rec install` (lib/cli-install.sh) and the install.sh
# --tools-only flag.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$(mktemp -d)"
  mkdir -p "$T/bin"
}
teardown() { rm -rf "$T"; }

@test "install.sh --tools-only --no-tools is a no-op (exits 0 without cloning)" {
  # PATH gives bash access to coreutils but the script never reaches a clone:
  # --no-tools combined with --tools-only short-circuits everything.
  run bash "$REPO_ROOT/install.sh" --tools-only --no-tools --unattended
  [ "$status" -eq 0 ]
  # Must NOT have hit clone_or_update — its banner contains "Cloning" or
  # "Updating existing checkout".
  [[ "$output" != *"Cloning"* ]]
  [[ "$output" != *"Updating existing checkout"* ]]
}
```

- [ ] **Step 2: Run the test, confirm it fails**

```bash
bats test/install.bats
```

Expected: fails (`--tools-only` unknown option, install.sh exits 2).

- [ ] **Step 3: Implement the flag in install.sh**

In `install.sh`, find the `--no-tools` case in the arg-parse loop (around line 123) and add `--tools-only` alongside it:

```sh
    --no-tools) INSTALL_TOOLS=none ;;
    --tools-only) TOOLS_ONLY=1 ;;
```

At the top of install.sh (with the other `INSTALL_*` defaults around line 28), add:

```sh
TOOLS_ONLY=0
```

In the `usage()` heredoc (around lines 30-54), add the new flag under the existing options block:

```
  --tools-only      Only install/refresh the modern CLI tools (skip clone,
                    rc-loader, oh-my-posh, zoxide). Useful when re-running
                    install.sh from an already-installed checkout.
```

Then guard the bootstrap sequence at the bottom of install.sh (the `# --- run ---` section around line 545):

```sh
# --- run -------------------------------------------------------------------
if [ "$TOOLS_ONLY" -eq 1 ]; then
  log "Installing/refreshing CLI tools only (--tools-only)"
  TARGET_DIR="${REC_SHELL_DIR:-$TARGET_DIR}"
  install_tools_all
  ok "tools install complete."
  exit 0
fi

log "Installing rec-shell (${C_B}${MODE}${C_0}) into ${C_B}${TARGET_DIR}${C_0}"
ensure_git
clone_or_update
install_loader_lines
install_profile_d_dropin
ensure_omp
ensure_zoxide
install_tools_all
```

(everything below stays unchanged — the banner / post-install instructions only run in the full path.)

- [ ] **Step 4: Run the test, confirm it passes**

```bash
bats test/install.bats
```

Expected: the new test passes.

- [ ] **Step 5: Lint**

```bash
shellcheck install.sh
shfmt -d -i 2 -ci -bn install.sh
```

- [ ] **Step 6: Commit**

```bash
git add install.sh test/install.bats
git commit -m "feat(install): --tools-only flag — skip bootstrap, install tools only"
```

---

## Task 4: lib/cli-install.sh — `rec install` command

**Files:**
- Create: `lib/cli-install.sh`
- Append-to: `test/install.bats` (existing from Task 3)

- [ ] **Step 1: Write the failing tests**

Append to `test/install.bats`:

```bash
# Source the module with a sandboxed PATH + stubbed install.sh.
install_in() {
  local shell="$1"
  shift
  run "$shell" -c "
    export HOME='$T' PATH='$T/bin:/usr/bin:/bin' REC_SHELL_DIR='$T/repo'
    REC_SHELL_NAME='$shell' REC_UI_PLAIN=1
    mkdir -p '$T/repo/lib' '$T/repo'
    cp '$REPO_ROOT/lib/core.sh' '$T/repo/lib/'
    cp '$REPO_ROOT/lib/ui.sh' '$T/repo/lib/'
    cp '$REPO_ROOT/lib/tools-catalog.sh' '$T/repo/lib/'
    cp '$REPO_ROOT/lib/cli-install.sh' '$T/repo/lib/'
    # Stub install.sh so we observe how rec install invokes it.
    cat > '$T/repo/install.sh' <<'EOF'
#!/bin/sh
echo \"INSTALL_CALL: \$*\"
exit 0
EOF
    chmod +x '$T/repo/install.sh'
    . '$T/repo/lib/core.sh'
    . '$T/repo/lib/ui.sh'
    . '$T/repo/lib/tools-catalog.sh'
    . '$T/repo/lib/cli-install.sh'
    $*"
}

@test "rec install help mentions list, run, and interactive forms" {
  install_in bash '__rec_install_help'
  [ "$status" -eq 0 ]
  [[ "$output" == *"list"* && "$output" == *"all"* ]]
}

@test "rec install list shows [✓]/[✗] markers per catalog tool" {
  # Stub two tools as installed, the rest absent.
  printf "#!/bin/sh\nexit 0\n" >"$T/bin/eza"
  printf "#!/bin/sh\nexit 0\n" >"$T/bin/bat"
  chmod +x "$T/bin/eza" "$T/bin/bat"
  install_in bash '__rec_install_list'
  [ "$status" -eq 0 ]
  # Installed tools render with the OK glyph (✓ / [ok]).
  [[ "$output" == *"eza"* && ( "$output" == *"✓"* || "$output" == *"[ok]"* ) ]]
}

@test "rec install <name> calls install.sh with --tools-only and --tools=NAME" {
  install_in bash '__rec_install_run fd'
  [ "$status" -eq 0 ]
  [[ "$output" == *"INSTALL_CALL:"* ]]
  [[ "$output" == *"--tools-only"* ]]
  [[ "$output" == *"--tools=fd"* ]]
  [[ "$output" == *"--unattended"* ]]
}

@test "rec install all installs every missing tool" {
  # Only eza is present, so rec install all should ask install.sh for the rest.
  printf "#!/bin/sh\nexit 0\n" >"$T/bin/eza"
  chmod +x "$T/bin/eza"
  install_in bash '__rec_install_dispatch all'
  [ "$status" -eq 0 ]
  [[ "$output" == *"INSTALL_CALL:"* ]]
  [[ "$output" == *"--tools=fd"* || "$output" == *",fd"* || "$output" == *"fd,"* ]]
  [[ "$output" != *"--tools=eza"* ]]
}

@test "rec install run with no missing tools exits 0 with a friendly message" {
  # Mark every catalog tool present via a rec_have override.
  install_in bash '
    rec_have() { return 0; }  # everything claims to exist
    rec_tools_present() { return 0; }
    __rec_install_dispatch all'
  [ "$status" -eq 0 ]
  [[ "$output" == *"already installed"* || "$output" == *"All tools"* ]]
}

@test "rec install <unknown-tool> errors with exit 2" {
  install_in bash '__rec_install_run no-such-tool'
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown tool"* ]]
}

@test "rec install dispatch with no TTY prints usage hint and exits 0" {
  install_in bash '__rec_install_dispatch'
  [ "$status" -eq 0 ]
  # Non-interactive: must NOT block on a multiselect. Either prints hint and
  # returns 0, or prints the same as `list` — either is acceptable here.
  [[ "$output" == *"rec install"* ]]
}
```

- [ ] **Step 2: Run, confirm all fail**

```bash
bats test/install.bats
```

Expected: tests 2-7 fail (cli-install.sh doesn't exist yet); test 1 (`--tools-only`) already passes from Task 3.

- [ ] **Step 3: Implement lib/cli-install.sh**

```sh
# shellcheck shell=sh
#
# lib/cli-install.sh — the `rec install` command. Lazy-loaded by lib/cli.sh.
# Drives an interactive multiselect over rec_tools_catalog and shells out
# to install.sh --tools-only to do the actual installation.

__rec_install_dispatch() {
  _rin_cmd="${1:-}"
  case "$_rin_cmd" in
    help | --help | -h)
      __rec_install_help
      return 0
      ;;
    list | ls)
      __rec_install_list
      return $?
      ;;
    all)
      __rec_install_run_missing
      return $?
      ;;
    '')
      __rec_install_interactive
      return $?
      ;;
    *)
      # Treat positional args as a list of tool names.
      __rec_install_run "$@"
      return $?
      ;;
  esac
}

__rec_install_help() {
  cat <<'EOF'
rec install — install modern CLI tools from the rec-shell catalog

Usage:
  rec install              Interactive multiselect of MISSING tools.
  rec install list         Show every catalog tool with [✓]/[✗] status.
  rec install all          Install every tool that is currently missing.
  rec install <tool>...    Install the named tools (skip prompts).
  rec install help         Show this help.

Tools are installed via install.sh --tools-only, so this never touches your
shell rc files or re-clones the repo.
EOF
}

# `rec install list` -> show every catalog tool with a status marker.
__rec_install_list() {
  rec_ui_heading "rec-shell tools"
  rec_tools_catalog | while IFS='|' read -r _ril_name _ril_bin _ril_kind _ril_pkgs _ril_desc; do
    [ -z "$_ril_name" ] && continue
    if rec_tools_present "$_ril_name"; then
      __rec_ui_emit 1 "$REC_UI_S_GREEN" "$REC_UI_G_OK"
      printf ' '
    else
      __rec_ui_emit 1 "$REC_UI_S_YELLOW" "$REC_UI_G_WARN"
      printf ' '
    fi
    __rec_ui_emit 1 "$REC_UI_S_CYAN" "$(printf '%-24s' "$_ril_name")"
    __rec_ui_emit 1 "$REC_UI_S_DIM" " $_ril_desc"
    printf '\n'
  done
  unset _ril_name _ril_bin _ril_kind _ril_pkgs _ril_desc
}

# `rec install <name>...` -> validate names against the catalog, then install.
__rec_install_run() {
  if [ $# -eq 0 ]; then
    rec_ui_err "rec install: at least one tool name is required"
    return 2
  fi
  _rin_valid=""
  for _rin_n in "$@"; do
    if [ -z "$(rec_tools_field "$_rin_n" 1)" ]; then
      rec_ui_err "rec install: unknown tool '$_rin_n'"
      return 2
    fi
    _rin_valid="$_rin_valid,$_rin_n"
  done
  _rin_valid="${_rin_valid#,}"
  __rec_install_exec "$_rin_valid"
  unset _rin_n _rin_valid
}

# `rec install all` -> compute the missing set, install everything in one go.
__rec_install_run_missing() {
  _rin_miss="$(rec_tools_missing | awk 'NF' | paste -sd, -)"
  if [ -z "$_rin_miss" ]; then
    rec_ui_ok "All tools already installed."
    return 0
  fi
  rec_ui_info "Installing: $_rin_miss"
  __rec_install_exec "$_rin_miss"
  unset _rin_miss
}

# Interactive multi-select over the MISSING tools.
__rec_install_interactive() {
  _rin_miss="$(rec_tools_missing | awk 'NF')"
  if [ -z "$_rin_miss" ]; then
    rec_ui_ok "All tools already installed."
    return 0
  fi
  if ! rec_ui_interactive_load || ! __rec_ui_interactive; then
    rec_ui_info 'Non-interactive shell; printing the list instead.'
    __rec_install_list
    rec_ui_note 'Pick by name: rec install <tool> ... (or: rec install all)'
    return 0
  fi
  # Build space-separated args for rec_ui_multiselect.
  set --
  # POSIX: build "$@" from the newline list.
  _rin_OLDIFS="$IFS"
  IFS='
'
  # shellcheck disable=SC2086  # intentional word split on newline
  set -- $_rin_miss
  IFS="$_rin_OLDIFS"
  rec_ui_multiselect "Tools to install (space to toggle, a = all, enter = confirm)" "$@" >/dev/null
  if [ -z "${REC_UI_REPLY:-}" ]; then
    rec_ui_info 'Nothing selected.'
    return 0
  fi
  _rin_csv="$(printf '%s' "$REC_UI_REPLY" | tr ' ' ',')"
  __rec_install_exec "$_rin_csv"
  unset _rin_miss _rin_OLDIFS _rin_csv
}

# Common exec path: invoke install.sh --tools-only with the given CSV list.
__rec_install_exec() {
  _rin_csv="$1"
  if [ ! -x "$REC_SHELL_DIR/install.sh" ] && [ ! -r "$REC_SHELL_DIR/install.sh" ]; then
    rec_ui_err "install.sh not found at $REC_SHELL_DIR/install.sh"
    return 1
  fi
  sh "$REC_SHELL_DIR/install.sh" --tools-only --unattended --tools="$_rin_csv"
  unset _rin_csv
}
```

- [ ] **Step 4: Run the tests, confirm they pass**

```bash
bats test/install.bats
```

Expected: all 7 tests pass.

- [ ] **Step 5: Lint**

```bash
shellcheck lib/cli-install.sh
shfmt -d -i 2 -ci -bn lib/cli-install.sh
```

- [ ] **Step 6: Commit**

```bash
git add lib/cli-install.sh test/install.bats
git commit -m "feat(install): rec install — interactive tool picker driven by tools-catalog"
```

---

## Task 5: wire `rec install` into lib/cli.sh

**Files:**
- Modify: `lib/cli.sh` (dispatch case, lazy-loader, help row, menu entry)

- [ ] **Step 1: Write the failing test**

Append to `test/smoke.bats` near the existing `rec port` / `rec ip` smokes (the file already has loader-driven tests for each registered command — add one for `install` in the same style):

```bash
@test "bash: rec install help dispatches via cli.sh" {
  REC_SHELL_ARGS="--norc" load_in bash 'rec install help'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rec install"* ]]
  [[ "$output" == *"list"* ]]
}
```

- [ ] **Step 2: Run, confirm fails**

```bash
bats test/smoke.bats -f 'rec install help'
```

Expected: `unknown command "install"` (exit 2).

- [ ] **Step 3: Add the dispatch case in lib/cli.sh**

Find the dispatch case-block (around lib/cli.sh:15-42) and add an entry near the other tool-related commands (after `dns`):

```sh
    dns) __rec_cmd_dns "$@" ;;
    install) __rec_cmd_install "$@" ;;
    password | passwd | pw) __rec_cmd_password "$@" ;;
```

- [ ] **Step 4: Add the lazy-loader function**

Near the other `__rec_cmd_*` lazy-loaders (around lib/cli.sh:380-460), after `__rec_cmd_dns`:

```sh
__rec_cmd_install() {
  if ! command -v __rec_install_dispatch >/dev/null 2>&1; then
    if [ -r "$REC_SHELL_DIR/lib/cli-install.sh" ]; then
      . "$REC_SHELL_DIR/lib/cli-install.sh"
    else
      rec_ui_err 'install commands unavailable (missing lib/cli-install.sh)'
      return 1
    fi
  fi
  __rec_install_dispatch "$@"
}
```

- [ ] **Step 5: Add the help row**

In `__rec_cmd_help`, after the `dns` row:

```sh
  __rec_help_row "dns <domain>" "DNS records: A, AAAA, MX, NS, TXT, CNAME, SOA"
  __rec_help_row "install [tool]" "Install modern CLI tools (interactive picker)"
  __rec_help_row "password" "Strong password generator (-> clipboard)"
```

- [ ] **Step 6: Add the menu entry**

In `__rec_cmd_menu`, after the `dns` entry:

```sh
    'dns       - DNS records (A/AAAA/MX/NS/TXT/CNAME/SOA)' \
    'install   - install modern CLI tools (interactive picker)' \
    'password  - strong password generator' \
```

- [ ] **Step 7: Run the test, confirm it passes**

```bash
bats test/smoke.bats -f 'rec install help'
```

Expected: pass.

- [ ] **Step 8: Lint + full suite**

```bash
shellcheck lib/cli.sh
shfmt -d -i 2 -ci -bn lib/cli.sh
bats test/
```

Expected: lint clean, all tests pass.

- [ ] **Step 9: Commit**

```bash
git add lib/cli.sh test/smoke.bats
git commit -m "feat(install): wire rec install into the top-level dispatcher + menu"
```

---

## Task 6: soft notification at the tail of `rec update`

**Files:**
- Modify: `lib/cli.sh:__rec_cmd_update`

- [ ] **Step 1: Write the failing test**

`test/update-cli.bats` already builds a 2-tag bare origin + a clone at `$T/inst` checked out to `v0.0.1` (see lines 6-48 in that file: `setup` + the `up_in` helper). Reuse that fixture: the test runs `rec update` (which bumps `$T/inst` to v0.0.2), but injects an in-process `rec_have` override so the catalog reports every tool as missing — which makes the nudge fire deterministically regardless of what's actually on the host.

Append to `test/update-cli.bats`:

```bash
@test "bash: rec update appends 'rec install' nudge when catalog tools are missing" {
  # Reuse the setup() fixture: $T/inst is at v0.0.1, $T/origin.git has v0.0.2.
  # Use a sanitized PATH and override rec_have so every catalog tool reads
  # as missing — this makes the assertion deterministic across mac/linux.
  run env -i \
    HOME="$T/home" PATH="/usr/bin:/bin" TERM=dumb \
    GIT_CONFIG_GLOBAL="$T/gc" GIT_CONFIG_SYSTEM=/dev/null \
    XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/home/.cache" \
    REC_UPDATE_CHECK=never \
    bash --norc -i -c "
      . '$T/inst/rec-shell.sh'
      rec_have() {
        case \$1 in
          fzf|atuin|eza|bat|fd|fdfind|rg|batcat|btop|ncdu|whois|dig) return 1 ;;
          *) command -v \$1 >/dev/null 2>&1 ;;
        esac
      }
      rec update 2>&1"
  [ "$status" -eq 0 ]
  # The nudge text from __rec_cmd_update (the exact wording from the plan).
  [[ "$output" == *"rec install"* ]]
  [[ "$output" == *"modern CLI tools available"* ]]
}

@test "bash: rec update on the newest tag stays quiet (no nudge on no-op)" {
  # When there's nothing to update, the function returns early before the
  # banner + nudge — the existing 'already up to date' message is the only
  # thing the user sees.
  git -C "$T/inst" checkout -q v0.0.2
  run env -i \
    HOME="$T/home" PATH="/usr/bin:/bin" TERM=dumb \
    GIT_CONFIG_GLOBAL="$T/gc" GIT_CONFIG_SYSTEM=/dev/null \
    XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/home/.cache" \
    REC_UPDATE_CHECK=never \
    bash --norc -i -c "
      . '$T/inst/rec-shell.sh'
      rec_have() {
        case \$1 in
          fzf|atuin|eza|bat|fd|fdfind|rg|batcat|btop|ncdu|whois|dig) return 1 ;;
          *) command -v \$1 >/dev/null 2>&1 ;;
        esac
      }
      rec update 2>&1"
  [[ "$output" == *"up to date"* ]]
  [[ "$output" != *"rec install"* ]]
}
```

- [ ] **Step 2: Run, confirm fails (or skipped)**

```bash
bats test/update-cli.bats
```

Expected: the new test fails or is skipped, existing ones still pass.

- [ ] **Step 3: Add the notification to __rec_cmd_update**

In `lib/cli.sh`, modify `__rec_cmd_update`. After the existing `rec_banner` call at the end (added in v1.3.2), append:

```sh
  rec_banner "$_rcu_new" "updated from $_rcu_old" "rec doctor"

  # Soft nudge: if any modern CLI tools are missing, mention rec install once.
  # This deliberately runs only when the version actually changed — quiet on
  # the "already up to date" path.
  if command -v rec_tools_count_missing >/dev/null 2>&1; then
    _rcu_missing="$(rec_tools_count_missing 2>/dev/null)"
    case "$_rcu_missing" in
      '' | 0) ;;
      *)
        rec_ui_note "$_rcu_missing modern CLI tools available — run: rec install"
        ;;
    esac
    unset _rcu_missing
  fi
}
```

- [ ] **Step 4: Run the test, confirm it passes**

```bash
bats test/update-cli.bats
```

Expected: pass (once the skip is removed and the fixture mirrored).

- [ ] **Step 5: Manual smoke (real env, no tag bump)**

```bash
bash -c '
  export REC_SHELL_DIR="$(pwd)" REC_SHELL_NAME=bash
  . ./lib/core.sh; . ./lib/ui.sh; . ./lib/tools-catalog.sh; . ./lib/cli.sh
  echo "missing: $(rec_tools_count_missing)"'
```

Expected: prints `missing: 0` (you ran `rec install` earlier; nothing left) or a small N.

- [ ] **Step 6: Commit**

```bash
git add lib/cli.sh test/update-cli.bats
git commit -m "feat(update): one-line nudge when modern CLI tools are missing"
```

---

## Task 7: README + final verification

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add the `rec install` row**

In README.md, in the Commands table — right after the `dns` row added in v1.3.0:

```markdown
| `dns <domain> [type]` | DNS records via `dig`: A, AAAA, MX, NS, TXT, CNAME, SOA |
| `install [tool]` | Install modern CLI tools (interactive multiselect) |
| `password` | Strong password generator (copies to clipboard by default) |
```

- [ ] **Step 2: Run the full suite + lint**

```bash
shfmt -d -i 2 -ci -bn rec-shell.sh install.sh uninstall.sh lib modules scripts
shellcheck rec-shell.sh install.sh uninstall.sh lib/*.sh modules/*.sh scripts/*.sh
bats test/
```

Expected: lint clean, all tests pass (190 existing + 7 new tools-catalog tests + 7 new install tests + 1 smoke + 1 update = 206 total, exact count may differ slightly).

- [ ] **Step 3: Manual end-to-end**

```bash
# 1. List shows all 12 tools with status markers.
rec install list

# 2. Interactive picker opens with missing tools only (TTY required).
rec install

# 3. Direct install of a specific tool (uses install.sh).
rec install ncdu        # picks the package manager and installs

# 4. After update, the nudge appears if any tool is still missing.
rec update              # (no-op if already up-to-date; nudge ONLY on real bump)

# 5. Doctor still reflects the catalog.
rec doctor
```

Expected: each command behaves as designed; no broken output.

- [ ] **Step 4: Commit + release**

```bash
git add README.md
git commit -m "docs: rec install entry in the commands table"

scripts/release.sh --minor -m="release v1.4.0 — rec install (interactive tool picker) + post-update nudge"
```

Expected: v1.4.0 tagged + pushed, CI green.

---

## Verification

After all tasks are merged:

1. `rec install list` — every catalog tool listed with ✓/⚠ marker, descriptions in dim.
2. `rec install` (interactive TTY) — multiselect over missing tools only, ESC = cancel, Enter = confirm, `a` = all.
3. `rec install <tool>` — validates against catalog, errors on unknown name with exit 2, shells out to `install.sh --tools-only --unattended --tools=<tool>` otherwise.
4. `rec install all` — installs every missing tool in one `install.sh` invocation.
5. `rec install` in a non-TTY (CI, pipe, ssh -T) — prints the list + a "pick by name" hint, never blocks.
6. `rec update` after a real version bump on a host with missing tools — appends one dim line "N modern CLI tools available — run: rec install" beneath the existing banner.
7. `rec doctor` — same ✓/✗ tools section as before, now driven from the shared catalog.
8. `install.sh --tools-only --unattended --tools=fd` — installs only fd, never touches rc/loader/omp/zoxide.
9. `bats test/` — all green on macOS (host) and on Ubuntu CI (now that the systemd test override pattern is the established convention for catalog gating).

## Out of Scope (for v1)

- Tracking "new since user's last update" so the nudge only fires when the catalog grew (would require a state file in `$REC_CACHE_DIR`). Out for v1 — the count-missing heuristic is good enough and the nudge appears only on real version bumps.
- Per-tool uninstall via `rec install --remove`. The reverse direction is a different feature with non-trivial PM semantics.
- A `rec install --dry-run` mode that prints the `install.sh` invocation without executing it. Could be added if users ask; not needed for v1.
