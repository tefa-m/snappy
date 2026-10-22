#!/bin/bash
# Bumps the Homebrew casks in the tap repo tefa-m/homebrew-snappy after a release:
#
#   scripts/update-tap.sh <version> <sha256>   render, brew style, commit, push
#   scripts/update-tap.sh --plan <version>     print what would change; touch nothing
#
# Rules (features/versioning.md):
#   Casks/snappy.rb       updated iff <version> is stable AND above its version
#   Casks/snappy@beta.rb  updated iff <version> (beta or stable) is above its
#                         version; created if missing (when above the stable cask)
# So a patch to an older line updates neither cask. Casks are rendered from
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
    if [ -n "$CUR_BETA" ]; then
        rl_gt "$V" "$CUR_BETA" && UPD_BETA=1
    elif [ -z "$CUR_STABLE" ] || rl_gt "$V" "$CUR_STABLE"; then
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
decide
echo "Tap: $(describe_plan)"
if [ "$UPD_STABLE" = 0 ] && [ "$UPD_BETA" = 0 ]; then
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
git -C "$TAP" push --quiet origin main || rl_die "pushing the tap failed — the commit is local in $TAP; push it by hand"
echo "Tap: committed and pushed Snappy $V ($TOKENS )"

for token in $TOKENS; do
    brew audit --cask --strict "tefa-m/snappy/$token" ||
        echo "WARNING: brew audit --cask --strict tefa-m/snappy/$token reported problems (not fatal)" >&2
done
exit 0
