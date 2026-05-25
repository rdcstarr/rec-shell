# shellcheck shell=bash
#
# lib/cli-git.sh — the `rec git` command group. Lazy-loaded by lib/cli.sh on the
# first `rec git ...`. Runs under bash and zsh. Output goes through the rec-shell
# UI toolkit (lib/ui.sh), so it is consistent and colors auto-off when piped.
#
#   rec git sync [--force]   update the current repo with the latest code from origin
#   rec git push [...]       stage everything, commit and push to the upstream
#   rec git release [...]    create the next semver tag and push it
#   rec git init --url=...   bootstrap a new repo and push it to GitHub

__rec_git_dispatch() {
  _rg_cmd="${1:-help}"
  [ $# -gt 0 ] && shift
  case "$_rg_cmd" in
    sync) __rec_git_sync "$@" ;;
    push) __rec_git_push "$@" ;;
    release) __rec_git_release "$@" ;;
    init) __rec_git_init "$@" ;;
    help | --help | -h) __rec_git_help ;;
    *)
      rec_ui_err "rec git: unknown command \"$_rg_cmd\""
      printf '\n' >&2
      __rec_git_help >&2
      return 2
      ;;
  esac
}

__rec_git_help() {
  cat <<'EOF'
rec git — git helpers

Usage: rec git <command>

Commands:
  sync [--force]      Update the current repo with the latest code from origin
                      (fetch + fast-forward). Refuses on local changes; --force
                      discards them and hard-resets to origin.
  push [...]          Stage everything, commit, and push to the upstream
  release [...]       Create the next semver tag (vX.Y.Z) and push it
  init --url=<url>    Initialize a new repo and push it to GitHub

Run `rec git <command> --help` for command-specific options.
EOF
}

# === rec git sync — bring the current repo up to date with origin ===
__rec_git_sync() {
  local FORCE=no arg
  for arg in "$@"; do
    case "$arg" in
      -f | --force) FORCE=yes ;;
      -h | --help)
        cat <<'EOF'
Usage: rec git sync [--force]

Fetch origin and fast-forward the current branch to the latest code.
Refuses when the working tree has uncommitted changes; --force discards
local changes and hard-resets the branch to its origin counterpart.
EOF
        return 0
        ;;
    esac
  done

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    rec_ui_err "You are not in a Git repository."
    return 1
  fi
  if ! git remote get-url origin >/dev/null 2>&1; then
    rec_ui_err "No 'origin' remote configured."
    return 1
  fi

  local BRANCH UPSTREAM
  BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ -z "$BRANCH" ] || [ "$BRANCH" = HEAD ]; then
    rec_ui_err "Detached HEAD; check out a branch first."
    return 1
  fi
  UPSTREAM="origin/$BRANCH"

  rec_ui_step "Fetching $UPSTREAM ..."
  if ! git fetch --quiet --prune origin; then
    rec_ui_err "Fetch failed (offline?)."
    return 1
  fi
  if ! git rev-parse --verify --quiet "$UPSTREAM" >/dev/null; then
    rec_ui_err "origin has no branch '$BRANCH'."
    return 1
  fi

  local counts ahead behind
  counts="$(git rev-list --left-right --count "HEAD...$UPSTREAM" 2>/dev/null)"
  ahead="${counts%%[!0-9]*}"
  behind="${counts##*[!0-9]}"
  [ -n "$ahead" ] || ahead=0
  [ -n "$behind" ] || behind=0

  # --force: discard local state and match origin exactly (deploy pattern).
  if [ "$FORCE" = yes ]; then
    if ! git reset --hard "$UPSTREAM" >/dev/null; then
      rec_ui_err "Reset failed."
      return 1
    fi
    rec_ui_ok "Forced $BRANCH to $UPSTREAM ($(git rev-parse --short HEAD))."
    return 0
  fi

  if [ "$behind" -eq 0 ]; then
    rec_ui_ok "Already up to date with $UPSTREAM."
    return 0
  fi

  if ! git diff --quiet || ! git diff --cached --quiet; then
    rec_ui_err "You have uncommitted changes ($behind commit(s) behind)."
    printf '   %s\n' "Commit or stash them, or run: rec git sync --force" >&2
    return 1
  fi
  if [ "$ahead" -gt 0 ]; then
    rec_ui_err "Your branch has diverged ($ahead ahead, $behind behind)."
    printf '   %s\n' "Push or rebase first, or run: rec git sync --force" >&2
    return 1
  fi

  if ! git merge --ff-only "$UPSTREAM" >/dev/null; then
    rec_ui_err "Fast-forward failed."
    return 1
  fi
  rec_ui_ok "Updated $BRANCH to $(git rev-parse --short HEAD) (+$behind commit(s))."
}

# === rec git release — next semver tag + push ===
__rec_git_release() {
  local DEFAULT_START="v1.0.0"
  local REMOTE="origin"
  local BRANCH=""
  local SET_VERSION=""
  local INCREMENT="auto"
  local ALLOW_DIRTY="no"
  local DRY_RUN="no"
  local MESSAGE=""

  for arg in "$@"; do
    case "$arg" in
      --v=* | --version=*) SET_VERSION="${arg#*=}" ;;
      --major) INCREMENT="major" ;;
      --minor) INCREMENT="minor" ;;
      --patch) INCREMENT="patch" ;;
      --start=*)
        DEFAULT_START="${arg#*=}"
        [[ "$DEFAULT_START" =~ ^v ]] || DEFAULT_START="v$DEFAULT_START"
        ;;
      --remote=*) REMOTE="${arg#*=}" ;;
      --branch=*) BRANCH="${arg#*=}" ;;
      --allow-dirty) ALLOW_DIRTY="yes" ;;
      -n | --dry-run) DRY_RUN="yes" ;;
      -m=*) MESSAGE="${arg#*=}" ;;
      -h | --help)
        cat <<'EOF'
Usage: rec git release [--v=1.2.3 | --major | --minor | --patch] [--start=1.0.0]
                       [--remote=origin] [--branch=<name>] [--allow-dirty]
                       [-n|--dry-run] [-m=message]

Without options: autoincrement (vX.Y.0 after vX.(Y-1).9, otherwise vX.Y.(Z+1)).
Examples:
  rec git release                 # v1.0.1 -> v1.0.2, v1.0.9 -> v1.1.0
  rec git release --v=1.2.0       # set directly to v1.2.0
  rec git release --minor         # bump minor (reset patch)
  rec git release -n              # show what it would do, without changing the repo
EOF
        return 0
        ;;
    esac
  done

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    rec_ui_err "You are not in a Git repository."
    return 1
  fi

  [ -z "$BRANCH" ] && BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"

  if [ "$ALLOW_DIRTY" = "no" ]; then
    if ! git diff --quiet || ! git diff --cached --quiet; then
      rec_ui_err "Working tree has uncommitted changes. Use --allow-dirty if intentional."
      return 1
    fi
  fi

  local LAST_TAG
  LAST_TAG="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --merged HEAD | sort -V | tail -n1)"

  local NEXT_TAG
  if [ -n "$SET_VERSION" ]; then
    [[ "$SET_VERSION" =~ ^v ]] || SET_VERSION="v$SET_VERSION"
    if [[ ! "$SET_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      rec_ui_err "Invalid version: $SET_VERSION (expected: vX.Y.Z or X.Y.Z)"
      return 1
    fi
    NEXT_TAG="$SET_VERSION"
  else
    local BASE="${LAST_TAG:-$DEFAULT_START}"
    [[ "$BASE" =~ ^v ]] || BASE="v$BASE"
    if [[ ! "$BASE" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      rec_ui_err "Last tag is not semver (vX.Y.Z): $BASE"
      return 1
    fi

    local VER="${BASE#v}"
    local MAJOR MINOR PATCH
    IFS='.' read -r MAJOR MINOR PATCH <<<"$VER"

    case "$INCREMENT" in
      major)
        MAJOR=$((MAJOR + 1))
        MINOR=0
        PATCH=0
        ;;
      minor)
        MINOR=$((MINOR + 1))
        PATCH=0
        ;;
      patch) PATCH=$((PATCH + 1)) ;;
      auto)
        if [ "$PATCH" -ge 9 ]; then
          PATCH=0
          if [ "$MINOR" -ge 9 ]; then
            MINOR=0
            MAJOR=$((MAJOR + 1))
          else
            MINOR=$((MINOR + 1))
          fi
        else
          PATCH=$((PATCH + 1))
        fi
        ;;
    esac

    NEXT_TAG="v${MAJOR}.${MINOR}.${PATCH}"
  fi

  if git rev-parse "$NEXT_TAG" >/dev/null 2>&1; then
    rec_ui_err "Tag $NEXT_TAG already exists."
    return 1
  fi

  local MSG="${MESSAGE:-$NEXT_TAG}"

  rec_ui_kv "Branch" "$BRANCH"
  rec_ui_kv "Remote" "$REMOTE"
  rec_ui_kv "Last tag" "${LAST_TAG:-(none)}"
  rec_ui_ok "Next tag: $NEXT_TAG"
  rec_ui_kv "Message" "$MSG"
  [ "$DRY_RUN" = "yes" ] && {
    rec_ui_info "(dry-run) Not creating tag and not pushing."
    return 0
  }

  if ! git tag -a "$NEXT_TAG" -m "$MSG"; then
    rec_ui_err "Error in 'git tag'."
    return 1
  fi

  if ! git push --atomic "$REMOTE" "$BRANCH" "$NEXT_TAG"; then
    rec_ui_err "Error in push. Deleting local tag created."
    git tag -d "$NEXT_TAG" >/dev/null 2>&1
    return 1
  fi

  rec_ui_ok "Done: $NEXT_TAG has been pushed to $REMOTE/$BRANCH."
}

# === rec git push — add + commit + push ===
__rec_git_push() {
  local MSG=""
  local PREFIX="chore"
  local REMOTE=""
  local BRANCH=""
  local NO_VERIFY="no"
  local SIGNOFF="no"
  local AMEND="no"
  local DRY_RUN="no"

  while [ $# -gt 0 ]; do
    case "$1" in
      -m)
        shift
        MSG="$1"
        ;;
      -m=* | --msg=*) MSG="${1#*=}" ;;
      --prefix=*) PREFIX="${1#*=}" ;;
      --remote=*) REMOTE="${1#*=}" ;;
      --branch=*) BRANCH="${1#*=}" ;;
      --no-verify) NO_VERIFY="yes" ;;
      --signoff) SIGNOFF="yes" ;;
      --amend) AMEND="yes" ;;
      -n | --dry-run) DRY_RUN="yes" ;;
      -h | --help)
        cat <<'EOF'
Usage: rec git push [-m "message"] [--prefix=chore|feat|fix|docs|...]
                    [--remote=origin] [--branch=main] [--no-verify] [--signoff]
                    [--amend] [-n|--dry-run]

Without options: stage everything, commit with a random message and push.
Examples:
  rec git push
  rec git push -m "feat: import products"
  rec git push --amend
  rec git push -n
EOF
        return 0
        ;;
    esac
    shift
  done

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    rec_ui_err "You are not in a Git repository."
    return 1
  fi

  local CUR_BRANCH
  CUR_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || CUR_BRANCH=""

  local UPSTREAM REMOTE_FROM_UPSTREAM BRANCH_FROM_UPSTREAM
  local SET_UPSTREAM="no"
  if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}')"
    REMOTE_FROM_UPSTREAM="${UPSTREAM%/*}"
    BRANCH_FROM_UPSTREAM="${UPSTREAM#*/}"
  fi

  local FINAL_REMOTE FINAL_BRANCH
  FINAL_REMOTE="${REMOTE:-${REMOTE_FROM_UPSTREAM:-origin}}"
  FINAL_BRANCH="${BRANCH:-${BRANCH_FROM_UPSTREAM:-${CUR_BRANCH}}}"
  [ -z "$BRANCH_FROM_UPSTREAM" ] && SET_UPSTREAM="yes"

  if [ -z "$(git status --porcelain)" ] && [ "$AMEND" = "no" ]; then
    rec_ui_info "No changes to push."
    return 0
  fi

  rec_ui_step "git add -A"
  [ "$DRY_RUN" = "yes" ] || git add -A

  if [ -z "$MSG" ] && [ "$AMEND" = "no" ]; then
    local RANDHEX
    RANDHEX="$(openssl rand -hex 2 2>/dev/null || printf '%06x' $((RANDOM % 65536)))"
    MSG="${PREFIX}: ${RANDHEX}"
  fi

  local COMMIT_ARGS=()
  [ "$SIGNOFF" = "yes" ] && COMMIT_ARGS+=("--signoff")
  [ "$NO_VERIFY" = "yes" ] && COMMIT_ARGS+=("--no-verify")

  if [ "$AMEND" = "yes" ]; then
    if [ -n "$MSG" ]; then
      rec_ui_step "git commit --amend -m \"$MSG\" ${COMMIT_ARGS[*]}"
      [ "$DRY_RUN" = "yes" ] || git commit --amend -m "$MSG" "${COMMIT_ARGS[@]}"
    else
      rec_ui_step "git commit --amend --no-edit ${COMMIT_ARGS[*]}"
      [ "$DRY_RUN" = "yes" ] || git commit --amend --no-edit "${COMMIT_ARGS[@]}"
    fi
  else
    rec_ui_step "git commit -m \"$MSG\" ${COMMIT_ARGS[*]}"
    if [ "$DRY_RUN" != "yes" ]; then
      if ! git commit -m "$MSG" "${COMMIT_ARGS[@]}"; then
        rec_ui_err "Commit failed (maybe no changes)."
        return 1
      fi
    fi
  fi

  local PUSH_FLAGS=()
  [ "$SET_UPSTREAM" = "yes" ] && PUSH_FLAGS+=("-u")

  rec_ui_step "git push ${PUSH_FLAGS[*]} \"$FINAL_REMOTE\" \"$FINAL_BRANCH\""
  [ "$DRY_RUN" = "yes" ] && return 0

  if ! git push "${PUSH_FLAGS[@]}" "$FINAL_REMOTE" "$FINAL_BRANCH"; then
    rec_ui_err "Error while pushing."
    return 1
  fi

  rec_ui_ok "Pushed to $FINAL_REMOTE/$FINAL_BRANCH."
}

# === rec git init — bootstrap a new repo and push to GitHub ===
__rec_git_init() {
  local REPO_URL=""
  local BRANCH="main"
  local README_TEXT=""
  local INITIAL_COMMIT="first commit"
  local DRY_RUN="no"

  while [ $# -gt 0 ]; do
    case "$1" in
      --url=*) REPO_URL="${1#*=}" ;;
      --branch=*) BRANCH="${1#*=}" ;;
      --readme=*) README_TEXT="${1#*=}" ;;
      --commit=*) INITIAL_COMMIT="${1#*=}" ;;
      -n | --dry-run) DRY_RUN="yes" ;;
      -h | --help)
        cat <<'EOF'
Usage: rec git init --url=<github-url> [--branch=main] [--readme="text"]
                    [--commit="first commit"] [-n|--dry-run]

Initialize a new Git repository and push to GitHub.
Examples:
  rec git init --url=https://github.com/user/repo.git
  rec git init --url=https://github.com/user/repo.git --readme="My Project"
EOF
        return 0
        ;;
      *)
        rec_ui_err "Unknown option: $1"
        printf '   %s\n' "Use --help for usage information." >&2
        return 1
        ;;
    esac
    shift
  done

  if [ -z "$REPO_URL" ]; then
    rec_ui_err "Repository URL is required. Use --url=<github-url>"
    return 1
  fi

  local REPO_NAME
  REPO_NAME="$(basename "$REPO_URL" .git)"
  [ -z "$README_TEXT" ] && README_TEXT="# ${REPO_NAME}"

  rec_ui_step "Initializing repository..."
  rec_ui_kv "URL" "$REPO_URL"
  rec_ui_kv "Branch" "$BRANCH"
  rec_ui_kv "Commit" "$INITIAL_COMMIT"

  if [ "$DRY_RUN" = "yes" ]; then
    rec_ui_info "(dry-run) Commands that would be executed:"
    printf '   %s\n' "echo \"$README_TEXT\" >> README.md"
    printf '   %s\n' "git init && git add -A && git commit -m \"$INITIAL_COMMIT\""
    printf '   %s\n' "git branch -M $BRANCH && git remote add origin $REPO_URL"
    printf '   %s\n' "git push -u origin $BRANCH"
    return 0
  fi

  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    rec_ui_err "Already a Git repository. Use 'git remote add origin <url>' instead."
    return 1
  fi

  rec_ui_step "git init"
  git init || {
    rec_ui_err "git init failed"
    return 1
  }

  if [ ! -f "README.md" ]; then
    rec_ui_step "Creating README.md..."
    echo "$README_TEXT" >README.md || {
      rec_ui_err "Failed to create README.md"
      return 1
    }
  fi

  rec_ui_step "git add -A"
  git add -A || {
    rec_ui_err "git add failed"
    return 1
  }

  rec_ui_step "git commit -m \"$INITIAL_COMMIT\""
  git commit -m "$INITIAL_COMMIT" || {
    rec_ui_err "git commit failed"
    return 1
  }

  rec_ui_step "git branch -M $BRANCH"
  git branch -M "$BRANCH" || {
    rec_ui_err "git branch failed"
    return 1
  }

  rec_ui_step "git remote add origin $REPO_URL"
  git remote add origin "$REPO_URL" || {
    rec_ui_err "git remote add failed"
    return 1
  }

  rec_ui_step "git push -u origin $BRANCH"
  if ! git push -u origin "$BRANCH"; then
    rec_ui_err "git push failed. Check your credentials and repository access."
    return 1
  fi

  rec_ui_ok "Repository initialized and pushed to $REPO_URL"
}
