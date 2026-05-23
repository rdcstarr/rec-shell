#!/usr/bin/env bash
#
# release.sh — cut a new rec-shell release. Maintainer tool; run from anywhere
# inside the rec-shell development repo. It bumps the VERSION file, commits it,
# creates the matching vX.Y.Z tag, and pushes the branch + tag.
#
#   scripts/release.sh             # patch bump (1.0.0 -> 1.0.1)
#   scripts/release.sh --minor     # 1.0.0 -> 1.1.0
#   scripts/release.sh --major     # 1.0.0 -> 2.0.0
#   scripts/release.sh --v=1.4.0   # set an exact version
#   scripts/release.sh -n          # dry-run (show what would happen)
#
# This is NOT `rec git release`: that one is generic (any repo, tag only). This
# one is rec-shell-specific because it owns the VERSION file that drives the
# update notification.

set -euo pipefail

INCREMENT="patch" # patch | minor | major
SET_VERSION=""
DRY_RUN=no
REMOTE=origin
MSG=""

usage() {
  sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --patch) INCREMENT="patch" ;;
    --minor) INCREMENT="minor" ;;
    --major) INCREMENT="major" ;;
    --v=* | --version=*) SET_VERSION="${1#*=}" ;;
    --remote=*) REMOTE="${1#*=}" ;;
    -m=* | --message=*) MSG="${1#*=}" ;;
    -n | --dry-run) DRY_RUN=yes ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "release: unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done

die() {
  echo "release: $*" >&2
  exit 1
}

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
cd "$ROOT"

# Must be the rec-shell repo (has VERSION + the loader).
[ -f VERSION ] || die "no VERSION file here — run this inside the rec-shell repo"
[ -f rec-shell.sh ] || die "this does not look like the rec-shell repo (no rec-shell.sh)"

# Guard against accidentally releasing from an installed copy.
case "$ROOT" in
  "$HOME/.rec-shell" | /opt/rec-shell)
    die "this is an installed copy ($ROOT), not the development repo"
    ;;
esac

# Clean tree required (we are about to commit only the VERSION bump).
if ! git diff --quiet || ! git diff --cached --quiet; then
  die "working tree has uncommitted changes; commit or stash them first"
fi

CURRENT="$(tr -d ' \t\r\n' <VERSION)"
case "$CURRENT" in
  '' | *[!0-9.]*) die "VERSION is not a plain semver: '$CURRENT'" ;;
esac

if [ -n "$SET_VERSION" ]; then
  NEXT="${SET_VERSION#v}"
else
  IFS=. read -r MA MI PA <<<"$CURRENT"
  MA="${MA:-0}" MI="${MI:-0}" PA="${PA:-0}"
  case "$INCREMENT" in
    major)
      MA=$((MA + 1))
      MI=0
      PA=0
      ;;
    minor)
      MI=$((MI + 1))
      PA=0
      ;;
    patch) PA=$((PA + 1)) ;;
  esac
  NEXT="$MA.$MI.$PA"
fi

case "$NEXT" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) die "computed version is not vX.Y.Z: '$NEXT'" ;;
esac

TAG="v$NEXT"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"

if git rev-parse "$TAG" >/dev/null 2>&1; then
  die "tag $TAG already exists"
fi

echo "current : $CURRENT"
echo "next    : $NEXT  ($TAG)"
echo "branch  : $BRANCH -> $REMOTE"

if [ "$DRY_RUN" = yes ]; then
  echo "(dry-run) nothing changed."
  exit 0
fi

# Bump VERSION only if it actually changes (allows tagging the current version).
if [ "$NEXT" != "$CURRENT" ]; then
  printf '%s\n' "$NEXT" >VERSION
  git add VERSION
  git commit -q -m "${MSG:-release $TAG}"
fi

git tag -a "$TAG" -m "${MSG:-$TAG}"

if ! git push --atomic "$REMOTE" "$BRANCH" "$TAG"; then
  echo "release: push failed; removing local tag $TAG" >&2
  git tag -d "$TAG" >/dev/null 2>&1 || true
  exit 1
fi

echo "🎉 released $TAG"
