#!/bin/bash
# Bumps the Homebrew casks in the tap repo tefa-m/homebrew-snappy after a release:
#
#   scripts/update-tap.sh <version> <sha256>   render, brew style, commit, push
#   scripts/update-tap.sh --plan <version>     print what would change; touch nothing
#
# Rules (features/versioning.md), against the casks as they are before the run:
#   Casks/snappy.rb       updated iff <version> is stable AND above its version
#   Casks/snappy@beta.rb  updated (or created if missing) iff <version> (beta or
#                         stable) is above both its version and the stable cask's
# So a patch to an older line updates neither cask, a stale beta cask is never
# moved below the stable one, and a newer stable moves both.
# Pending local "Snappy <version>" cask commits from a run whose push failed are
# pushed first; success is only reported once origin/main has the casks. Casks are rendered from
# scripts/templates/*.rb.tmpl. The tap is the clone at SNAPPY_TAP_DIR (default:
# ../homebrew-snappy next to the main checkout); it must be clean and on main.
# Never touches Homebrew's own clone of the tap (under brew --repository).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/scripts/lib/release-lib.sh"

PLAN=0
if [ "${1:-}" = --plan ]; then PLAN=1; shift; fi
V=${1:-} SUM=${2:-}
V=${V#v}
rl_valid "$V" || { echo "usage: $0 <version> <sha256> | $0 --plan <version>" >&2; exit 2; }
if [ "$PLAN" = 0 ]; then
    [[ $SUM =~ ^[0-9a-f]{64}$ ]] || { echo "usage: $0 <version> <sha256>  (sha256: 64 lowercase hex)" >&2; exit 2; }
fi

if [ -z "${SNAPPY_TAP_DIR:-}" ]; then
    COMMON=$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)
    SNAPPY_TAP_DIR="$(dirname "$COMMON")/../homebrew-snappy"
fi
[ -d "$SNAPPY_TAP_DIR" ] || rl_die "tap dir $SNAPPY_TAP_DIR does not exist (set SNAPPY_TAP_DIR)"
TAP=$(cd "$SNAPPY_TAP_DIR" && pwd -P)
case $TAP in
    /opt/homebrew/* | /usr/local/Homebrew/* | */Library/Taps/*) rl_die "$TAP is Homebrew's own clone — use your working clone of the tap" ;;
esac
[ "$(git -C "$TAP" rev-parse --show-toplevel 2>/dev/null)" = "$TAP" ] || rl_die "$TAP is not the root of a git repository"
[ "$(git -C "$TAP" branch --show-current)" = main ] || rl_die "tap $TAP is not on main"
[ -z "$(git -C "$TAP" status --porcelain)" ] || rl_die "tap $TAP has uncommitted changes"

cask_version() {
    [ -f "$1" ] || return 0
    sed -n 's/^  version "\(.*\)"$/\1/p' "$1" | head -n 1
}

decide() {
    CUR_STABLE=$(cask_version "$TAP/Casks/snappy.rb")
    CUR_BETA=$(cask_version "$TAP/Casks/snappy@beta.rb")
    UPD_STABLE=0 UPD_BETA=0
    if [ "$(rl_channel "$V")" != beta ] && { [ -z "$CUR_STABLE" ] || rl_gt "$V" "$CUR_STABLE"; }; then
        UPD_STABLE=1
    fi
    if { [ -z "$CUR_BETA" ] || rl_gt "$V" "$CUR_BETA"; } && { [ -z "$CUR_STABLE" ] || rl_gt "$V" "$CUR_STABLE"; }; then
        UPD_BETA=1
    fi
    return 0
}

describe_plan() {
    local s=unchanged b=unchanged
    [ "$UPD_STABLE" = 1 ] && s="${CUR_STABLE:-new} -> $V"
    if [ "$UPD_BETA" = 1 ]; then b="${CUR_BETA:-new} -> $V"; fi
    echo "snappy: $s (${CUR_STABLE:-missing}); snappy@beta: $b (${CUR_BETA:-missing})  [$TAP]"
}

if [ "$PLAN" = 1 ]; then
    decide
    describe_plan
    exit 0
fi

command -v brew >/dev/null || rl_die "brew is not installed"
git -C "$TAP" pull --ff-only --quiet || rl_die "git pull --ff-only in $TAP failed"

# A previous run may have committed but failed to push: push those commits
# (only update-tap's own cask commits), anything else is for a human.
AHEAD=$(git -C "$TAP" rev-list --count origin/main..main)
if [ "$AHEAD" != 0 ]; then
    OTHER=$(git -C "$TAP" log --format='%s' origin/main..main | grep -v '^Snappy [0-9][^ ]*: ' || true)
    FOREIGN=$(git -C "$TAP" diff --name-only origin/main main | grep -v -x -e 'Casks/snappy.rb' -e 'Casks/snappy@beta.rb' || true)
    [ -z "$OTHER$FOREIGN" ] ||
        rl_die "tap main is $AHEAD commit(s) ahead of origin/main with changes update-tap.sh did not make — push or drop them by hand ($TAP)"
    echo "Tap: pushing $AHEAD pending cask commit(s) from an earlier run"
    git -C "$TAP" push --quiet origin main || rl_die "pushing the pending tap commit(s) failed — origin/main is still stale; fix and re-run"
fi

# verify_remote <file>... — origin/main must equal local main, and every given
# cask on origin/main must carry $V and $SUM.
verify_remote() {
    local f
    git -C "$TAP" fetch --quiet origin || rl_die "git fetch in $TAP failed — cannot verify the pushed casks"
    [ "$(git -C "$TAP" rev-parse main)" = "$(git -C "$TAP" rev-parse origin/main)" ] ||
        rl_die "tap origin/main differs from local main after the push — the casks are not published"
    for f in "$@"; do
        git -C "$TAP" show "origin/main:$f" | grep -qx "  version \"$V\"" &&
            git -C "$TAP" show "origin/main:$f" | grep -qx "  sha256 \"$SUM\"" ||
            rl_die "origin/main:$f does not carry version $V / sha256 $SUM"
    done
}

decide
echo "Tap: $(describe_plan)"
for f in snappy snappy@beta; do
    if [ "$(cask_version "$TAP/Casks/$f.rb")" = "$V" ] && ! grep -qx "  sha256 \"$SUM\"" "$TAP/Casks/$f.rb"; then
        rl_die "Casks/$f.rb is already at $V but with a different sha256 than $SUM — check the release asset"
    fi
done
if [ "$UPD_STABLE" = 0 ] && [ "$UPD_BETA" = 0 ]; then
    verify_remote
    echo "Tap: no cask change for $V"
    exit 0
fi

mkdir -p "$TAP/Casks"
FILES="" TOKENS=""
render() {
    sed -e "s/@@VERSION@@/$V/g" -e "s/@@SHA256@@/$SUM/g" "$ROOT/scripts/templates/$1.rb.tmpl" >"$TAP/Casks/$1.rb"
    FILES="$FILES Casks/$1.rb" TOKENS="$TOKENS $1"
}
[ "$UPD_STABLE" = 0 ] || render snappy
[ "$UPD_BETA" = 0 ] || render snappy@beta

# shellcheck disable=SC2086 # FILES/TOKENS are space-separated, no spaces inside
if ! (cd "$TAP" && brew style $FILES); then
    git -C "$TAP" checkout -- . && git -C "$TAP" clean -fq -- Casks
    rl_die "brew style failed — tap left unchanged"
fi
# shellcheck disable=SC2086
git -C "$TAP" add $FILES
git -C "$TAP" commit --quiet -m "Snappy $V:$TOKENS"
git -C "$TAP" push --quiet origin main ||
    rl_die "pushing the tap failed — the commit is local in $TAP; re-run this command (or --resume) to push it"
# shellcheck disable=SC2086
verify_remote $FILES
echo "Tap: committed and pushed Snappy $V ($TOKENS )"

for token in $TOKENS; do
    brew audit --cask --strict "tefa-m/snappy/$token" ||
        echo "WARNING: brew audit --cask --strict tefa-m/snappy/$token reported problems (not fatal)" >&2
done
exit 0
