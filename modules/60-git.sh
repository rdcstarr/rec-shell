# shellcheck shell=bash
#
# Git helpers: git_release (semver tag + push), git_push (add/commit/push),
# git_init_repo (bootstrap a new repo). Run under bash and zsh.

# === Git release helper (semver) ===
git_release() {
  local DEFAULT_START="v1.0.0"
  local REMOTE="origin"
  local BRANCH=""
  local SET_VERSION=""
  local INCREMENT="auto" # auto | major | minor | patch
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
Usage: git_release [--v=1.2.3 | --major | --minor | --patch] [--start=1.0.0]
                   [--remote=origin] [--branch=<name>] [--allow-dirty] [-n|--dry-run]
                   [-m=message]

Without options: autoincrement (vX.Y.0 after vX.(Y-1).9, otherwise vX.Y.(Z+1))
Examples:
  git_release                 # v1.0.1 -> v1.0.2, v1.0.9 -> v1.1.0
  git_release --v=1.2.0       # set directly to v1.2.0
  git_release --minor         # bump minor (reset patch)
  git_release --major         # bump major (reset minor/patch)
  git_release -n              # show what it would do, without modifying repo
EOF
        return 0
        ;;
    esac
  done

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "❌ You are not in a Git repository."
    return 1
  fi

  [ -z "$BRANCH" ] && BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"

  if [ "$ALLOW_DIRTY" = "no" ]; then
    if ! git diff --quiet || ! git diff --cached --quiet; then
      echo "❌ Working tree has uncommitted changes. Use --allow-dirty if intentional."
      return 1
    fi
  fi

  local LAST_TAG
  LAST_TAG="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --merged HEAD | sort -V | tail -n1)"

  local NEXT_TAG
  if [ -n "$SET_VERSION" ]; then
    [[ "$SET_VERSION" =~ ^v ]] || SET_VERSION="v$SET_VERSION"
    if [[ ! "$SET_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "❌ Invalid version: $SET_VERSION (expected: vX.Y.Z or X.Y.Z)"
      return 1
    fi
    NEXT_TAG="$SET_VERSION"
  else
    local BASE="${LAST_TAG:-$DEFAULT_START}"
    [[ "$BASE" =~ ^v ]] || BASE="v$BASE"
    if [[ ! "$BASE" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "❌ Last tag is not semver (vX.Y.Z): $BASE"
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
    echo "❌ Tag $NEXT_TAG already exists."
    return 1
  fi

  local MSG="${MESSAGE:-$NEXT_TAG}"

  echo "➡️  Branch: $BRANCH"
  echo "➡️  Remote: $REMOTE"
  echo "➡️  Last tag: ${LAST_TAG:-(none)}"
  echo "✅  Next tag: $NEXT_TAG"
  echo "📝  Message: $MSG"
  [ "$DRY_RUN" = "yes" ] && {
    echo "(dry-run) Not creating tag and not pushing."
    return 0
  }

  if ! git tag -a "$NEXT_TAG" -m "$MSG"; then
    echo "❌ Error in 'git tag'."
    return 1
  fi

  if ! git push --atomic "$REMOTE" "$BRANCH" "$NEXT_TAG"; then
    echo "❌ Error in push. Deleting local tag created."
    git tag -d "$NEXT_TAG" >/dev/null 2>&1
    return 1
  fi

  echo "🎉 Done: $NEXT_TAG has been pushed to $REMOTE/$BRANCH."
}

# === Git quick push (add + commit + push) ===
git_push() {
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
Usage: push [-m "message"] [--prefix=chore|feat|fix|docs|refactor|style|test|perf]
            [--remote=origin] [--branch=main] [--no-verify] [--signoff] [--amend]
            [-n|--dry-run]

Without options: stage everything, commit with a random message and push to upstream.
Examples:
  push
  push -m "feat: import products"
  push --prefix=fix
  push --no-verify
  push --amend               # amend the last commit
  push -n                    # show what it would do
EOF
        return 0
        ;;
    esac
    shift
  done

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "❌ You are not in a Git repository."
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
    echo "ℹ️  No changes to push."
    return 0
  fi

  echo "➕  git add -A"
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
      echo "📝  git commit --amend -m \"$MSG\" ${COMMIT_ARGS[*]}"
      [ "$DRY_RUN" = "yes" ] || git commit --amend -m "$MSG" "${COMMIT_ARGS[@]}"
    else
      echo "📝  git commit --amend --no-edit ${COMMIT_ARGS[*]}"
      [ "$DRY_RUN" = "yes" ] || git commit --amend --no-edit "${COMMIT_ARGS[@]}"
    fi
  else
    echo "📝  git commit -m \"$MSG\" ${COMMIT_ARGS[*]}"
    if [ "$DRY_RUN" != "yes" ]; then
      if ! git commit -m "$MSG" "${COMMIT_ARGS[@]}"; then
        echo "❌ Commit failed (maybe no changes)."
        return 1
      fi
    fi
  fi

  # Build push flags as an array so an empty value never becomes an empty arg
  # (avoids the bash/zsh unquoted-word-splitting difference).
  local PUSH_FLAGS=()
  [ "$SET_UPSTREAM" = "yes" ] && PUSH_FLAGS+=("-u")

  echo "🚀  git push ${PUSH_FLAGS[*]} \"$FINAL_REMOTE\" \"$FINAL_BRANCH\""
  [ "$DRY_RUN" = "yes" ] && return 0

  if ! git push "${PUSH_FLAGS[@]}" "$FINAL_REMOTE" "$FINAL_BRANCH"; then
    echo "❌ Error while pushing."
    return 1
  fi

  echo "✅  Pushed to $FINAL_REMOTE/$FINAL_BRANCH."
}

# === Git init helper for new repos ===
git_init_repo() {
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
Usage: git_init_repo --url=<github-url> [--branch=main] [--readme="text"] [--commit="first commit"] [-n|--dry-run]

Initialize a new Git repository and push to GitHub.
Examples:
  git_init_repo --url=https://github.com/user/repo.git
  git_init_repo --url=https://github.com/user/repo.git --readme="My Project"
  git_init_repo --url=https://github.com/user/repo.git --branch=master
  git_init_repo -n --url=https://github.com/user/repo.git  # dry-run
EOF
        return 0
        ;;
      *)
        echo "❌ Unknown option: $1"
        echo "Use --help for usage information."
        return 1
        ;;
    esac
    shift
  done

  if [ -z "$REPO_URL" ]; then
    echo "❌ Repository URL is required. Use --url=<github-url>"
    return 1
  fi

  local REPO_NAME
  REPO_NAME="$(basename "$REPO_URL" .git)"
  [ -z "$README_TEXT" ] && README_TEXT="# ${REPO_NAME}"

  echo "📦  Initializing repository..."
  echo "➡️  URL: $REPO_URL"
  echo "➡️  Branch: $BRANCH"
  echo "➡️  Commit: $INITIAL_COMMIT"

  if [ "$DRY_RUN" = "yes" ]; then
    echo "(dry-run) Commands that would be executed:"
    echo "  echo \"$README_TEXT\" >> README.md"
    echo "  git init"
    echo "  git add -A"
    echo "  git commit -m \"$INITIAL_COMMIT\""
    echo "  git branch -M $BRANCH"
    echo "  git remote add origin $REPO_URL"
    echo "  git push -u origin $BRANCH"
    return 0
  fi

  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "❌ Already a Git repository. Use 'git remote add origin <url>' instead."
    return 1
  fi

  echo "🔧  git init"
  git init || {
    echo "❌ git init failed"
    return 1
  }

  if [ ! -f "README.md" ]; then
    echo "📝  Creating README.md..."
    echo "$README_TEXT" >README.md || {
      echo "❌ Failed to create README.md"
      return 1
    }
  fi

  echo "➕  git add -A"
  git add -A || {
    echo "❌ git add failed"
    return 1
  }

  echo "📝  git commit -m \"$INITIAL_COMMIT\""
  git commit -m "$INITIAL_COMMIT" || {
    echo "❌ git commit failed"
    return 1
  }

  echo "🌿  git branch -M $BRANCH"
  git branch -M "$BRANCH" || {
    echo "❌ git branch failed"
    return 1
  }

  echo "🔗  git remote add origin $REPO_URL"
  git remote add origin "$REPO_URL" || {
    echo "❌ git remote add failed"
    return 1
  }

  echo "🚀  git push -u origin $BRANCH"
  if ! git push -u origin "$BRANCH"; then
    echo "❌ git push failed. Check your credentials and repository access."
    return 1
  fi

  echo "✅  Repository initialized and pushed to $REPO_URL"
}
