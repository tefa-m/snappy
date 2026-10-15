#!/bin/bash
# Cuts a release: scripts/release.sh <MAJOR.MINOR.PATCH> ["release notes"]
#
# Refuses unless on a clean, up-to-date `main` with a green test gate and an
# unused tag; then creates the annotated tag v<version> and pushes main + tag.
# The tag message holds the release notes (no CHANGELOG.md). Bump rules and the
# whole flow: docs/features/versioning.md.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:-}
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 <MAJOR.MINOR.PATCH> [notes]" >&2; exit 2; }
TAG="v$VERSION"
LAST=$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true)

fail() { echo "ERROR: $1" >&2; exit 1; }

[ "$(git branch --show-current)" = main ] || fail "not on main"
[ -z "$(git status --porcelain)" ] || fail "working tree is not clean"
git fetch -q origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main differs from origin/main — pull or push first"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "tag $TAG already exists"

if [ -n "$LAST" ]; then
    # sort -V: the new version must be strictly greater than the last tag.
    [ "$(printf '%s\n%s\n' "${LAST#v}" "$VERSION" | sort -V | tail -1)" = "$VERSION" ] || fail "$VERSION is not newer than $LAST"
    [ "$(git rev-list --count "$LAST"..HEAD)" -gt 0 ] || fail "nothing new since $LAST"
    NOTES=${2:-$(git log --format='- %s' "$LAST"..HEAD)}
else
    NOTES=${2:-"First versioned release."}
fi

echo "Releasing $TAG (previous: ${LAST:-none})"
./scripts/test.sh
git tag -a "$TAG" -m "Snappy $VERSION

$NOTES"
git push origin main "$TAG"
echo "Released $TAG"
