#!/bin/bash
# Cuts a release on one of the three channels (features/versioning.md):
#
#   scripts/release.sh beta [minor|major] ["headline"]  next beta of the open train,
#                                                        else a new train (default minor) -> beta.1
#   scripts/release.sh stable ["headline"]              promote the open beta train to X.Y.0
#   scripts/release.sh patch ["headline"]               next X.Y.Z on release/X.Y (current branch)
#   scripts/release.sh <X.Y.Z[-beta.N]> ["headline"]    explicit version, same rules
#   scripts/release.sh --resume <version>               finish a release whose tag is already pushed
#
#   --dry-run  plan, tests, build, local tag — then deletes the tag; nothing is
#              pushed, published or tap-updated (no y/N prompt). With --resume:
#              read-only — prints what the resume would do
#   --yes      skip the y/N prompt (required when stdin is not a TTY)
#
# Betas and stables are cut from origin/main, patches from origin/release/X.Y —
# never from the local checkout: tests and the build run in a temporary detached
# worktree. Order: plan + confirm -> tests -> local annotated tag -> package
# (SnappyBuildDescription must equal the version exactly) -> git push --atomic
# branch + tag -> draft GitHub release with the zip -> download it back and
# verify its SHA-256 -> publish -> update the Homebrew tap (update-tap.sh).
# A failure before the push deletes the local tag; after the push the script
# prints how to --resume. --resume runs the provenance gate unless the release is
# already published, and only publishes an asset whose SHA-256 matches the one
# recorded in the draft notes (a rebuilt asset rewrites that record first).
# A published version is never re-tagged: ship the next.
#
# Environment: SNAPPY_RELEASE_ALLOW_UNBETAED=1 (stable without a beta on the same
# commit), SNAPPY_RELEASE_TEST_CMD (test gate, default ./scripts/test.sh),
# SNAPPY_RELEASE_SKIP_BUILD=1 (stub zip; tests still run; sandbox tests only),
# SNAPPY_RELEASE_REPO (gh repo, default tefa-m/snappy), SNAPPY_TAP_DIR.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
source scripts/lib/release-lib.sh

usage() {
    echo "usage:" >&2
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit "${1:-2}"
}

DRY_RUN=0 YES=0 RESUME=0 STATE="" POS1="" POS2="" POS3="" NPOS=0
for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=1 ;;
        --yes | -y) YES=1 ;;
        --resume) RESUME=1 ;;
        -h | --help) usage 0 ;;
        -*) echo "unknown option: $arg" >&2; usage ;;
        *)
            NPOS=$((NPOS + 1))
            case $NPOS in 1) POS1=$arg ;; 2) POS2=$arg ;; 3) POS3=$arg ;; *) usage ;; esac ;;
    esac
done
[ -n "$POS1" ] || usage

die() { rl_die "$@"; }

# --- state for the EXIT trap ---------------------------------------------------
WORK="" WT="" TAG="" TAG_CREATED=0 PUSHED=0 DONE=0
cleanup() {
    local rc=$?
    if [ -n "$WT" ] && [ -d "$WT" ]; then git -C "$ROOT" worktree remove --force "$WT" 2>/dev/null || true; fi
    git -C "$ROOT" worktree prune 2>/dev/null || true
    if [ "$TAG_CREATED" = 1 ] && [ "$PUSHED" = 0 ]; then
        git -C "$ROOT" tag -d "$TAG" >/dev/null 2>&1 && echo "Deleted local tag $TAG (nothing was pushed)." >&2
    fi
    if [ "$PUSHED" = 1 ] && [ "$DONE" = 0 ]; then
        cat >&2 <<EOF

!! $TAG is pushed but the release is not finished. Never re-tag it. Continue with:
     scripts/release.sh --resume ${TAG#v}
   or by hand:
     gh release create $TAG <zip> -R $RL_REPO_SLUG --draft --verify-tag --title "Snappy ${TAG#v}" --notes-file <notes>
     gh release edit $TAG -R $RL_REPO_SLUG --draft=false   (--prerelease for a beta)
     scripts/update-tap.sh ${TAG#v} <sha256>
EOF
    fi
    [ -z "$WORK" ] || rm -rf "$WORK"
    exit "$rc"
}
trap cleanup EXIT

confirm() {
    [ "$YES" = 1 ] && return 0
    [ -t 0 ] || die "stdin is not a TTY — re-run with --yes to confirm the plan"
    local ans
    read -r -p "Proceed? [y/N] " ans
    case $ans in y | Y | yes | YES) ;; *) die "aborted" ;; esac
}

gh_release() { local sub=$1; shift; gh release "$sub" -R "$RL_REPO_SLUG" "$@"; }

rl_info "Fetching origin"
git fetch --quiet --prune --tags origin || die "git fetch origin failed (a local tag that differs from origin's?)"

# --- resolve the version ------------------------------------------------------
HEADLINE=""
LATEST=$(rl_latest_stable)
if [ "$RESUME" = 1 ]; then
    rl_valid "$POS1" || die "--resume needs an explicit version, e.g. --resume 1.5.0-beta.2"
    V=${POS1#v}; HEADLINE=$POS2
else
    case $POS1 in
        beta)
            BUMP=""
            case $POS2 in
                major | minor) BUMP=$POS2; HEADLINE=$POS3 ;;
                patch) die "betas are X.Y.0 only; a fix for a shipped line goes through scripts/backport.sh + 'release.sh patch'" ;;
                *) HEADLINE=$POS2; [ -z "$POS3" ] || usage ;;
            esac
            TRAIN=$(rl_open_train)
            if [ -n "$TRAIN" ]; then
                if [ -n "$BUMP" ] && [ "$(rl_bump "${LATEST#v}" "$BUMP")" != "$TRAIN" ]; then
                    die "beta train v$TRAIN is open; finish it with 'stable' or start another train with an explicit version"
                fi
                V="$TRAIN-beta.$(rl_next_beta_n "$TRAIN")"
            else
                [ -n "$LATEST" ] || die "no stable tag to start a train from — pass an explicit version (e.g. 1.0.0-beta.1)"
                V="$(rl_bump "${LATEST#v}" "${BUMP:-minor}")-beta.1"
            fi ;;
        stable)
            HEADLINE=$POS2; [ -z "$POS3" ] || usage
            V=$(rl_open_train)
            [ -n "$V" ] || die "no open beta train to promote (latest stable: ${LATEST:-none}); cut a beta first" ;;
        patch)
            HEADLINE=$POS2; [ -z "$POS3" ] || usage
            CUR=$(git branch --show-current)
            case $CUR in
                release/*) LINE=${CUR#release/} ;;
                *)
                    BRS=$(git for-each-ref --format='%(refname:strip=3)' 'refs/remotes/origin/release/')
                    [ "$(printf '%s' "$BRS" | grep -c .)" = 1 ] ||
                        die "switch to the release/X.Y branch to patch (or pass an explicit X.Y.Z); origin has: ${BRS:-no release branches}"
                    LINE=${BRS#release/} ;;
            esac
            PREV_LINE_TAG=$(rl_line_tags "$LINE" | head -n 1 || true)
            [ -n "$PREV_LINE_TAG" ] || die "no v$LINE.* tag — nothing to patch"
            V=$(rl_bump "${PREV_LINE_TAG#v}" patch) ;;
        *)
            rl_valid "$POS1" || usage
            V=${POS1#v}; HEADLINE=$POS2; [ -z "$POS3" ] || usage ;;
    esac
fi

TAG="v$V"
CHANNEL=$(rl_channel "$V")
rl_parse "$V"
CORE="$RL_X.$RL_Y.$RL_Z" LINE="$RL_X.$RL_Y"
case $CHANNEL in
    beta) [ "$RL_Z" = 0 ] || die "betas are X.Y.0-beta.N only (got $V)"; BRANCH=main ;;
    stable) BRANCH=main ;;
    patch) BRANCH="release/$LINE" ;;
esac

# --- validate -------------------------------------------------------------------
remote_has_tag() { git ls-remote --exit-code --tags origin "refs/tags/$1" >/dev/null 2>&1; }

if [ "$RESUME" = 1 ]; then
    remote_has_tag "$TAG" || die "$TAG is not on origin — nothing to resume (delete a stale local tag with 'git tag -d $TAG', then run without --resume)"
    rl_tag_exists "$TAG" || die "$TAG is on origin but was not fetched"
    COMMIT=$(rl_commit_of "$TAG")
    PUSHED=1
    command -v gh >/dev/null || die "gh is not installed"
    STATE=$(gh_release view "$TAG" --json isDraft --jq .isDraft 2>/dev/null || echo missing)
    # Anything that can still publish passes the provenance gate; repairing the
    # tap of an already published release does not need it.
    [ "$STATE" = false ] || rl_provenance_gate origin/main || exit 1
else
    remote_has_tag "$TAG" && die "tag $TAG already exists on origin — use --resume $V to finish it, or ship the next number"
    rl_tag_exists "$TAG" && die "tag $TAG already exists locally (published versions are never re-tagged — ship the next number)"
    git rev-parse -q --verify "refs/remotes/origin/$BRANCH" >/dev/null ||
        die "origin/$BRANCH does not exist (a release branch is created by: scripts/backport.sh $LINE <merge-sha>... --push)"
    COMMIT=$(git rev-parse "refs/remotes/origin/$BRANCH")

    case $CHANNEL in
        beta)
            [ -z "$LATEST" ] || rl_gt "$CORE" "$LATEST" || die "$CORE must be above the latest stable $LATEST"
            WANT=$(rl_next_beta_n "$CORE")
            [ "$RL_N" = "$WANT" ] || die "the next beta of $CORE is beta.$WANT, not beta.$RL_N" ;;
        stable)
            [ -z "$LATEST" ] || rl_gt "$V" "$LATEST" || die "$V must be above the latest stable $LATEST"
            LAST_BETA=$(rl_betas_of "$CORE" | head -n 1 || true)
            if [ "${SNAPPY_RELEASE_ALLOW_UNBETAED:-0}" != 1 ]; then
                [ -n "$LAST_BETA" ] || die "$V has no beta — cut one first (or SNAPPY_RELEASE_ALLOW_UNBETAED=1)"
                [ "$(rl_commit_of "$LAST_BETA")" = "$COMMIT" ] ||
                    die "origin/main ($(git rev-parse --short "$COMMIT")) is not the commit of $LAST_BETA ($(git rev-parse --short "$LAST_BETA")) — cut another beta first (or SNAPPY_RELEASE_ALLOW_UNBETAED=1)"
            fi ;;
        patch)
            TOP=$(rl_line_tags "$LINE" | head -n 1 || true)
            [ -n "$TOP" ] || die "no v$LINE.* tag — nothing to patch"
            [ "$(rl_bump "${TOP#v}" patch)" = "$V" ] || die "the next patch of $LINE is $(rl_bump "${TOP#v}" patch), not $V"
            git merge-base --is-ancestor "$TOP" "$COMMIT" || die "$TOP is not an ancestor of origin/$BRANCH" ;;
    esac
    PREV=$(rl_prev_tag "$V" "$COMMIT")
    if [ -n "$PREV" ] && [ "$CHANNEL" != stable ] && [ "$(rl_commit_of "$PREV")" = "$COMMIT" ]; then
        die "nothing new on origin/$BRANCH since $PREV"
    fi
    rl_provenance_gate origin/main || exit 1
fi
PREV=$(rl_prev_tag "$V" "$COMMIT")
BODY=$(rl_notes_body "$V" "$COMMIT" "$HEADLINE")

# --- plan -----------------------------------------------------------------------
PUBLISH_FLAGS="--prerelease"
if [ "$CHANNEL" != beta ]; then
    if [ -z "$LATEST" ] || ! rl_gt "$LATEST" "$V"; then PUBLISH_FLAGS="--latest"; else PUBLISH_FLAGS="--latest=false"; fi
fi
LOCAL_BR=$(git rev-parse -q --verify "refs/heads/$BRANCH" 2>/dev/null || true)
TAP_PLAN=$("$ROOT/scripts/update-tap.sh" --plan "$V" 2>&1) || TAP_BAD=1

cat <<EOF

Release plan$([ "$DRY_RUN" = 1 ] && echo " (DRY RUN)")$([ "$RESUME" = 1 ] && echo " (RESUME, GitHub release: $STATE)")
  version   $V  ($CHANNEL)
  tag       $TAG  (annotated)
  branch    origin/$BRANCH
  commit    $(git log -1 --format='%h %s' "$COMMIT")
  base      ${PREV:-none}
  push      $([ "$RESUME" = 1 ] && echo "(done: $TAG is on origin)" || echo "git push --atomic origin $(git rev-parse --short "$COMMIT"):refs/heads/$BRANCH refs/tags/$TAG")
  publish   GitHub release $RL_REPO_SLUG $TAG: draft -> verify SHA-256 -> publish $PUBLISH_FLAGS
  tap       $(printf '%s' "$TAP_PLAN" | sed '2,$s/^/            /')
EOF
if [ -n "$LOCAL_BR" ] && [ "$LOCAL_BR" != "$COMMIT" ]; then
    echo "  note      your local $BRANCH differs from origin/$BRANCH — only origin/$BRANCH is released"
fi
printf '\n--- notes preview ---\n%s\n---------------------\n\n' "$BODY"
if [ "${TAP_BAD:-0}" = 1 ]; then
    [ "$DRY_RUN" = 1 ] && echo "WARNING: the tap is not ready (see above); a real release would stop here." >&2 ||
        die "the tap is not ready (see above) — fix it before releasing"
fi
[ "$DRY_RUN" = 1 ] || confirm

# --- build ----------------------------------------------------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/snappy-release.XXXXXX")
WT="$WORK/wt"
ZIP="$WORK/Snappy-$V.zip"
NOTES="$WORK/notes.md"

# build_zip — package the tagged commit in the temp worktree into $ZIP.
build_zip() {
    local desc
    if [ "${SNAPPY_RELEASE_SKIP_BUILD:-0}" = 1 ]; then
        desc=$(cd "$WT" && bash -c 'source scripts/version.sh; echo "$SNAPPY_DESCRIPTION"')
        mkdir -p "$WT/dist"
        printf 'Snappy %s (stub zip, SNAPPY_RELEASE_SKIP_BUILD)\n' "$desc" >"$WT/dist/Snappy-$desc.zip"
    else
        (cd "$WT" && ./scripts/package.sh) || die "scripts/package.sh failed"
        desc=$(/usr/libexec/PlistBuddy -c 'Print :SnappyBuildDescription' "$WT/dist/Snappy.app/Contents/Info.plist")
    fi
    [ "$desc" = "$V" ] || die "the build reports SnappyBuildDescription '$desc', expected exactly '$V'"
    [ -f "$WT/dist/Snappy-$V.zip" ] || die "dist/Snappy-$V.zip was not produced"
    cp "$WT/dist/Snappy-$V.zip" "$ZIP"
}

sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

# verify_asset — download the release asset and compare it with $ZIP.
verify_asset() {
    rm -rf "$WORK/dl" && mkdir -p "$WORK/dl"
    gh_release download "$TAG" --pattern "Snappy-$V.zip" --dir "$WORK/dl" || die "could not download the release asset back"
    [ "$(sha_of "$WORK/dl/Snappy-$V.zip")" = "$SUM" ] || die "downloaded asset SHA-256 differs from the built zip"
    rl_info "Asset verified: $SUM"
}

write_notes() { { printf '%s\n' "$BODY"; rl_notes_footer "$V" "$PREV" "$SUM"; } >"$NOTES"; }

publish() {
    # shellcheck disable=SC2086 # PUBLISH_FLAGS is one flag, never empty
    gh_release edit "$TAG" --draft=false $PUBLISH_FLAGS || die "publishing the release failed"
    rl_info "Published $TAG"
}

update_tap() { "$ROOT/scripts/update-tap.sh" "$V" "$SUM" || die "tap update failed"; }

# recorded_sum — the SHA-256 the release notes record for the zip (empty if none).
# It is written when the draft is created from the locally built zip, so it is
# the independent reference for an asset found on a draft or published release.
recorded_sum() {
    gh_release view "$TAG" --json body --jq .body 2>/dev/null |
        sed -n "s/^SHA-256 (\`Snappy-${V//./\\.}\\.zip\`): \`\([0-9a-f]\{64\}\)\`\$/\1/p" | tail -n 1 || true
}

# fetch_asset — download the release asset into $WORK/dl; fails if it is absent.
fetch_asset() {
    rm -rf "$WORK/dl" && mkdir -p "$WORK/dl"
    gh_release download "$TAG" --pattern "Snappy-$V.zip" --dir "$WORK/dl" 2>/dev/null && [ -f "$WORK/dl/Snappy-$V.zip" ]
}

if [ "$RESUME" = 1 ]; then
    # Read-only checks shared by --dry-run and the real resume (fail closed).
    EXP="" ASSET=""
    case $STATE in
        true | false)
            EXP=$(recorded_sum)
            if fetch_asset; then ASSET=$(sha_of "$WORK/dl/Snappy-$V.zip"); fi
            [ "$STATE" = false ] || [ -n "$EXP" ] ||
                die "the draft's notes record no SHA-256 for Snappy-$V.zip, so its asset cannot be verified — delete the draft (gh release delete $TAG -R $RL_REPO_SLUG) and --resume again"
            if [ -n "$ASSET" ] && [ -n "$EXP" ] && [ "$ASSET" != "$EXP" ]; then
                die "the release asset's SHA-256 $ASSET differs from the $EXP recorded in the notes — not publishing. Remove the asset (gh release delete-asset $TAG Snappy-$V.zip -R $RL_REPO_SLUG) and --resume to rebuild it"
            fi
            [ "$STATE" = true ] || [ -n "$ASSET" ] || die "could not download the published asset Snappy-$V.zip" ;;
        missing) ;;
        *) die "unexpected release state '$STATE'" ;;
    esac

    if [ "$DRY_RUN" = 1 ]; then
        echo "DRY RUN — --resume would:"
        case $STATE in
            missing) echo "  build Snappy-$V.zip from $TAG in a temporary worktree (tests are not re-run)"
                     echo "  gh release create $TAG --draft with the zip and notes, download it back, verify its SHA-256" ;;
            true) if [ -n "$ASSET" ]; then
                      echo "  reuse the draft asset (SHA-256 $ASSET, matches the notes)"
                  else
                      echo "  rebuild Snappy-$V.zip from $TAG (the draft has no asset), record its SHA-256 in the"
                      echo "  draft notes if it differs from $EXP, upload it, download it back and verify it"
                  fi ;;
        esac
        [ "$STATE" = false ] && echo "  skip publishing ($TAG is already published; asset SHA-256 $ASSET)" ||
            echo "  publish $TAG ($PUBLISH_FLAGS)"
        echo "  update the tap: scripts/update-tap.sh $V ${ASSET:-<sha256>}"
        echo "Nothing was pushed, uploaded, published or committed."
        DONE=1
        exit 0
    fi

    case $STATE in
        missing)
            git worktree add --quiet --detach "$WT" "$COMMIT"
            build_zip; SUM=$(sha_of "$ZIP"); write_notes
            gh_release create "$TAG" "$ZIP" --draft --verify-tag --title "Snappy $V" --notes-file "$NOTES" || die "creating the draft failed"
            verify_asset; publish ;;
        true)
            if [ -n "$ASSET" ]; then
                cp "$WORK/dl/Snappy-$V.zip" "$ZIP"; SUM=$ASSET
                rl_info "Draft asset matches the recorded SHA-256: $SUM"
            else
                git worktree add --quiet --detach "$WT" "$COMMIT"
                build_zip; SUM=$(sha_of "$ZIP")
                if [ "$SUM" != "$EXP" ]; then
                    # A rebuilt zip need not be byte-identical: record the new checksum first.
                    gh_release view "$TAG" --json body --jq .body >"$WORK/old-notes.md" || die "could not read the draft notes"
                    sed "s/^SHA-256 (\`Snappy-${V//./\\.}\\.zip\`): \`$EXP\`\$/SHA-256 (\`Snappy-$V.zip\`): \`$SUM\`/" "$WORK/old-notes.md" >"$NOTES"
                    gh_release edit "$TAG" --notes-file "$NOTES" || die "updating the draft notes failed"
                    [ "$(recorded_sum)" = "$SUM" ] || die "the draft notes do not record the rebuilt SHA-256 $SUM — not publishing"
                    rl_info "Draft notes now record the rebuilt SHA-256: $SUM"
                fi
                gh_release upload "$TAG" "$ZIP" --clobber || die "uploading the asset failed"
                verify_asset
            fi
            publish ;;
        false)
            cp "$WORK/dl/Snappy-$V.zip" "$ZIP"; SUM=$ASSET
            [ -n "$EXP" ] || echo "WARNING: the notes of $TAG record no SHA-256; using the published asset's $SUM" >&2 ;;
    esac
    update_tap
    DONE=1
    echo "Released $TAG (resumed)"
    exit 0
fi

rl_info "Temporary worktree of origin/$BRANCH at $(git rev-parse --short "$COMMIT")"
git worktree add --quiet --detach "$WT" "$COMMIT"
rl_info "Running tests"
rl_run_tests "$WT" || die "tests failed"

printf 'Snappy %s\n\n%s\n' "$V" "$BODY" >"$WORK/tagmsg"
git tag -a "$TAG" "$COMMIT" -F "$WORK/tagmsg"
TAG_CREATED=1
rl_info "Packaging $TAG"
build_zip
SUM=$(sha_of "$ZIP")
write_notes

if [ "$DRY_RUN" = 1 ]; then
    cat <<EOF

DRY RUN complete — built Snappy-$V.zip (SHA-256 $SUM). Not done:
  git push --atomic origin $COMMIT:refs/heads/$BRANCH refs/tags/$TAG
  gh release create/edit $TAG ($PUBLISH_FLAGS)
  scripts/update-tap.sh $V $SUM
--- release notes ---
$(cat "$NOTES")
EOF
    DONE=1
    exit 0
fi

command -v gh >/dev/null || die "gh is not installed"
rl_info "Pushing $BRANCH + $TAG (atomic)"
git push --atomic --quiet origin "$COMMIT:refs/heads/$BRANCH" "refs/tags/$TAG" || die "push failed — nothing was pushed"
PUSHED=1

gh_release create "$TAG" "$ZIP" --draft --verify-tag --title "Snappy $V" --notes-file "$NOTES" || die "creating the draft release failed"
verify_asset
publish
update_tap
DONE=1
echo "Released $TAG"
