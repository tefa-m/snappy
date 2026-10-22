#!/bin/bash
# Back-ports fixes that already landed on main to a shipped line:
#
#   scripts/backport.sh <X.Y> <merge-sha>... [--push]
#
# Creates release/X.Y from the highest stable tag vX.Y.* if it does not exist,
# then — in a temporary worktree, never in your checkout — runs
# `git cherry-pick -x -m 1` for each sha (each must be an ancestor of
# origin/main; one commit per fix, with the "(cherry picked from commit …)"
# trailer the release provenance gate checks) and the test gate. On a conflict
# or red tests the branch is reset to where it was. --push pushes the branch
# (git push -u). Nothing is tagged or published: finish with
# `scripts/release.sh patch` on release/X.Y.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
source scripts/lib/release-lib.sh

usage() { echo "usage: $0 <X.Y> <merge-sha>... [--push]" >&2; exit 2; }

PUSH=0 LINE="" SHAS=""
for arg in "$@"; do
    case $arg in
        --push) PUSH=1 ;;
        -h | --help) usage ;;
        -*) echo "unknown option: $arg" >&2; usage ;;
        *) if [ -z "$LINE" ]; then LINE=$arg; else SHAS="$SHAS $arg"; fi ;;
    esac
done
[[ $LINE =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || usage
[ -n "$SHAS" ] || usage
BRANCH="release/$LINE"

rl_info "Fetching origin"
git fetch --quiet --prune --tags origin

# Resolve and check every sha before touching anything.
FULL=""
for s in $SHAS; do
    c=$(git rev-parse -q --verify "$s^{commit}") || rl_die "unknown commit $s"
    git merge-base --is-ancestor "$c" origin/main ||
        rl_die "$s is not on origin/main — land the fix on main first (release branches only get back-ports)"
    FULL="$FULL $c"
done

LOCAL=$(git rev-parse -q --verify "refs/heads/$BRANCH" || true)
REMOTE=$(git rev-parse -q --verify "refs/remotes/origin/$BRANCH" || true)
CREATED=0
if [ -n "$LOCAL" ]; then
    if [ -n "$REMOTE" ] && ! git merge-base --is-ancestor "$REMOTE" "$LOCAL"; then
        rl_die "local $BRANCH has diverged from origin/$BRANCH — reconcile it first"
    fi
elif [ -n "$REMOTE" ]; then
    git branch --quiet --track "$BRANCH" "origin/$BRANCH"
else
    BASE=$(rl_line_tags "$LINE" | head -n 1 || true)
    [ -n "$BASE" ] || rl_die "no stable tag v$LINE.* to create $BRANCH from"
    rl_info "Creating $BRANCH from $BASE"
    git branch --quiet --no-track "$BRANCH" "$BASE"
    CREATED=1
fi
START=$(git rev-parse "refs/heads/$BRANCH")

WORK=$(mktemp -d "${TMPDIR:-/tmp}/snappy-backport.XXXXXX")
WT="$WORK/wt"
OK=0
cleanup() {
    local rc=$?
    if [ "$OK" = 0 ] && [ -d "$WT" ]; then
        git -C "$WT" cherry-pick --abort >/dev/null 2>&1 || true
        git -C "$WT" reset --quiet --hard "$START" 2>/dev/null || true
    fi
    [ ! -d "$WT" ] || git worktree remove --force "$WT" 2>/dev/null || true
    git worktree prune 2>/dev/null || true
    if [ "$OK" = 0 ] && [ "$CREATED" = 1 ]; then git branch -q -D "$BRANCH" 2>/dev/null || true; fi
    rm -rf "$WORK"
    exit "$rc"
}
trap cleanup EXIT

git worktree add --quiet "$WT" "$BRANCH" ||
    rl_die "could not check out $BRANCH in a temporary worktree (is it checked out elsewhere? switch away from it)"

for c in $FULL; do
    rl_info "Cherry-picking $(git log -1 --format='%h %s' "$c")"
    if ! git -C "$WT" cherry-pick -x -m 1 "$c" >/dev/null; then
        cat >&2 <<EOF
ERROR: cherry-pick of $(git rev-parse --short "$c") conflicts; $BRANCH is left as it was.
Resolve it by hand:
  git switch $BRANCH
  git cherry-pick -x -m 1 $c
  # fix the conflicts, then: git add <files> && git cherry-pick --continue
  ./scripts/test.sh && git push -u origin $BRANCH
EOF
        exit 1
    fi
done

rl_info "Running tests on $BRANCH"
rl_run_tests "$WT" || rl_die "tests failed on $BRANCH with the picks — branch reset to where it was"
OK=1

if [ "$PUSH" = 1 ]; then
    git push --quiet -u origin "$BRANCH"
    rl_info "Pushed $BRANCH"
fi
cat <<EOF
$BRANCH is ready: $(git rev-list --count "$START..$BRANCH") commit(s) picked.
Next:$([ "$PUSH" = 1 ] || printf '\n  git push -u origin %s' "$BRANCH")
  git switch $BRANCH && scripts/release.sh patch
EOF
