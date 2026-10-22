#!/bin/bash
# Sandbox tests for the release tooling (release.sh, backport.sh, update-tap.sh,
# version.sh, lib/release-lib.sh). Run with macOS /bin/bash (3.2):
#
#   /bin/bash scripts/test-release.sh        (KEEP=1 keeps the sandbox dir)
#
# Everything happens in a mktemp dir: throwaway repos with a local bare "origin",
# a throwaway tap repo, and PATH shims for gh and brew that only log and keep
# state in files. No network, no real remote, no real tag, no Homebrew changes.
# The Swift build and tests are replaced via SNAPPY_RELEASE_SKIP_BUILD=1 and
# SNAPPY_RELEASE_TEST_CMD.
set -uo pipefail
SRC=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/snappy-release-test.XXXXXX")
T=$(cd "$T" && pwd -P)
if [ "${KEEP:-0}" = 1 ]; then echo "sandbox: $T"; else trap 'rm -rf "$T"' EXIT; fi

# --- isolated git + shims ------------------------------------------------------
cat >"$T/gitconfig" <<'EOF'
[user]
	name = Release Test
	email = release-test@example.invalid
[init]
	defaultBranch = main
[commit]
	gpgSign = false
[tag]
	gpgSign = false
[advice]
	detachedHead = false
EOF
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
export SNAPPY_RELEASE_SKIP_BUILD=1 SNAPPY_RELEASE_TEST_CMD=true SNAPPY_RELEASE_REPO=sandbox/snappy
unset SNAPPY_RELEASE_ALLOW_UNBETAED SNAPPY_TAP_DIR
mkdir -p "$T/bin"
export PATH="$T/bin:$PATH"

# gh shim: `gh release <sub> <tag> -R <repo> ...`, state under $GH_STATE/<tag>/.
cat >"$T/bin/gh" <<'EOF'
#!/bin/bash
echo "gh $*" >>"$GH_STATE/log"
[ "$1" = release ] || { echo "gh shim: only 'gh release' is supported" >&2; exit 1; }
sub=$2; shift 2
tag="" pos="" pattern="" dir="" notes="" flags=""
while [ $# -gt 0 ]; do
    case $1 in
        -R | --json | --jq) shift 2 ;;
        --pattern) pattern=$2; shift 2 ;;
        --dir) dir=$2; shift 2 ;;
        --notes-file) notes=$2; shift 2 ;;
        --title) shift 2 ;;
        -*) flags="$flags $1"; shift ;;
        *) if [ -z "$tag" ]; then tag=$1; else pos=$1; fi; shift ;;
    esac
done
d="$GH_STATE/$tag"
case $sub in
    view) [ -d "$d" ] || { echo "release not found" >&2; exit 1; }; cat "$d/isDraft" ;;
    create)
        [ -z "${GH_FAIL_CREATE:-}" ] || { echo "gh shim: simulated create failure" >&2; exit 1; }
        [ ! -d "$d" ] || { echo "release exists" >&2; exit 1; }
        mkdir -p "$d"; echo true >"$d/isDraft"; cp "$pos" "$d/"; cp "$notes" "$d/notes.md"; echo "$flags" >"$d/create-flags" ;;
    upload) cp "$pos" "$d/" ;;
    download) [ -f "$d/$pattern" ] || exit 1; cp "$d/$pattern" "$dir/" ;;
    edit) case $flags in *--draft=false*) echo false >"$d/isDraft" ;; esac; echo "$flags" >"$d/edit-flags" ;;
    *) exit 1 ;;
esac
EOF
cat >"$T/bin/brew" <<'EOF'
#!/bin/bash
echo "brew $*" >>"$BREW_LOG"
case $1 in
    style) exit "${BREW_STYLE_RC:-0}" ;;
    audit) exit 0 ;;
    *) echo "brew shim: refusing 'brew $1'" >&2; exit 1 ;;
esac
EOF
chmod +x "$T/bin/gh" "$T/bin/brew"
export GH_STATE="$T/gh" BREW_LOG="$T/brew.log"
mkdir -p "$GH_STATE"; : >"$GH_STATE/log"; : >"$BREW_LOG"

# --- assertions -----------------------------------------------------------------
PASS=0 FAIL=0 OUT=""
ok() { PASS=$((PASS + 1)); echo "  ok    $1"; }
bad() {
    FAIL=$((FAIL + 1)); echo "  FAIL  $1"
    [ -z "${2:-}" ] || printf '%s\n' "$2" | tail -n 30 | sed 's/^/          | /'
}
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: $2
actual:   $3"; fi; }
has() { if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"; else bad "$1 (missing '$2')" "$3"; fi; }
hasnt() { if printf '%s' "$3" | grep -qF -- "$2"; then bad "$1 (unexpected '$2')" "$3"; else ok "$1"; fi; }
succeeds() { local d=$1; shift; if OUT=$("$@" 2>&1); then ok "$d"; else bad "$d" "$OUT"; fi; }
fails() {
    local d=$1 p=$2; shift 2
    if OUT=$("$@" 2>&1); then bad "$d (unexpectedly succeeded)" "$OUT"
    elif printf '%s' "$OUT" | grep -qF -- "$p"; then ok "$d"
    else bad "$d (wrong error, wanted '$p')" "$OUT"; fi
}
section() { echo; echo "## $1"; }

# --- sandbox builders -----------------------------------------------------------
# new_sandbox <name> — $R repo (clone of bare $O), a stable v1.0.0 on main, and
# a tap ($TAPGIT bare + $TAP clone) whose stable cask is 1.0.0.
new_sandbox() {
    local base="$T/$1"
    O="$base/origin.git" R="$base/repo" TAPGIT="$base/tap.git" TAP="$base/tap"
    git init -q --bare "$O"
    git init -q "$R"
    mkdir -p "$R/scripts"
    cp -R "$SRC/scripts/release.sh" "$SRC/scripts/backport.sh" "$SRC/scripts/update-tap.sh" \
        "$SRC/scripts/version.sh" "$SRC/scripts/lib" "$SRC/scripts/templates" "$R/scripts/"
    echo base >"$R/README"
    git -C "$R" add -A && git -C "$R" commit -q -m "Initial"
    git -C "$R" remote add origin "$O"
    git -C "$R" tag -a v1.0.0 -m "Snappy 1.0.0"
    git -C "$R" push -q -u origin main v1.0.0
    git init -q --bare "$TAPGIT"
    git clone -q "$TAPGIT" "$TAP" 2>/dev/null
    mkdir -p "$TAP/Casks"
    sed -e 's/@@VERSION@@/1.0.0/' -e "s/@@SHA256@@/$(printf '0%.0s' $(seq 64))/" \
        "$SRC/scripts/templates/snappy.rb.tmpl" >"$TAP/Casks/snappy.rb"
    git -C "$TAP" add -A && git -C "$TAP" commit -q -m "Snappy 1.0.0 cask"
    git -C "$TAP" push -q origin main
    export SNAPPY_TAP_DIR="$TAP" GH_STATE="$base/gh" BREW_LOG="$base/brew.log"
    mkdir -p "$GH_STATE"; : >"$GH_STATE/log"; : >"$BREW_LOG"
}
g() { git -C "$R" "$@"; }
# merge_feature <name> — a --no-ff feature merge on main, pushed; prints its sha.
merge_feature() {
    g switch -q main
    g switch -q -c "feat/$1"
    echo "$1" >"$R/$1.txt"; g add "$1.txt"; g commit -q -m "Add $1"
    g switch -q main
    g merge -q --no-ff -m "Merge feat/$1: $1" "feat/$1"
    g branch -q -D "feat/$1"
    g push -q origin main
    g rev-parse HEAD
}
rel() { (cd "$R" && ./scripts/release.sh "$@" </dev/null); }
bp() { (cd "$R" && ./scripts/backport.sh "$@" </dev/null); }
remote_tag() { git -C "$O" rev-parse -q --verify "refs/tags/$1" >/dev/null; }
local_tag() { g rev-parse -q --verify "refs/tags/$1" >/dev/null; }
cask_ver() { git -C "$TAPGIT" show "main:Casks/$1.rb" 2>/dev/null | sed -n 's/^  version "\(.*\)"$/\1/p'; }
lib() { (cd "$R" && source scripts/lib/release-lib.sh && "$@"); }

# =================================================================================
section "versions: parse, compare, tag order"
(
    source "$SRC/scripts/lib/release-lib.sh"
    for v in 1.2.3 v1.2.3 0.0.1 10.20.30 1.5.0-beta.1 1.5.0-beta.11; do
        if rl_valid "$v"; then ok "valid $v"; else bad "valid $v"; fi
    done
    for v in 1.2 01.2.3 1.02.3 1.2.3-beta.0 1.2.3-beta.01 1.2.3-rc.1 1.2.3-beta 1.2.3-1 x1.2.3 ""; do
        if rl_valid "$v"; then bad "invalid '$v'"; else ok "invalid '$v'"; fi
    done
    while read -r a b want; do
        eq "cmp $a $b" "$want" "$(rl_cmp "$a" "$b")"
    done <<'EOF'
1.5.0-beta.2 1.5.0-beta.11 -1
1.5.0-beta.11 1.5.0 -1
1.5.0 1.5.0-beta.11 1
1.4.9 1.5.0-beta.1 -1
1.10.0 1.9.0 1
2.0.0 1.99.99 1
1.5.0 1.5.0 0
1.5.0-beta.3 1.5.0-beta.3 0
1.5.1 1.5.0 1
EOF
    echo "PASS=$PASS FAIL=$FAIL" >"$T/sub.counts"
)
. "$T/sub.counts"

new_sandbox order
for t in v1.4.0 v1.4.1 v1.5.0-beta.1 v1.5.0-beta.2 v1.5.0-beta.11 v1.5.0 v1.10.0 v1.2 vjunk v1.5.0-rc.1; do
    g tag -a "$t" -m "$t"
done
eq "rl_tags: versionsort order, junk ignored" \
    "v1.10.0 v1.5.0 v1.5.0-beta.11 v1.5.0-beta.2 v1.5.0-beta.1 v1.4.1 v1.4.0 v1.0.0" \
    "$(lib rl_tags | tr '\n' ' ' | sed 's/ $//')"
ORDER_OK=1
TAGS=$(lib rl_tags)
PREVT=""
for t in $TAGS; do
    if [ -n "$PREVT" ] && [ "$(lib rl_cmp "$PREVT" "$t")" != 1 ]; then ORDER_OK=0; fi
    PREVT=$t
done
eq "rl_tags order agrees with rl_cmp pairwise" 1 "$ORDER_OK"
eq "rl_betas_of 1.5.0: beta.11 first" "v1.5.0-beta.11 v1.5.0-beta.2 v1.5.0-beta.1" "$(lib rl_betas_of 1.5.0 | tr '\n' ' ' | sed 's/ $//')"
eq "rl_latest_stable" v1.10.0 "$(lib rl_latest_stable)"
eq "no open train when the core has a stable tag" "" "$(lib rl_open_train)"

new_sandbox sortv
g tag -a v1.5.0-beta.1 -m b1
g tag -a v1.5.0 -m s
SORTV_LATEST=$(printf '%s\n' 1.5.0 1.5.0-beta.1 | sort -V | tail -n 1)
echo "  info  plain sort -V calls '$SORTV_LATEST' the latest of {1.5.0, 1.5.0-beta.1}"
eq "old sort -V bug not reproduced: latest tag is v1.5.0" v1.5.0 "$(lib rl_tags | head -n 1)"
eq "latest stable is v1.5.0, not the beta" v1.5.0 "$(lib rl_latest_stable)"
eq "1.5.0 > 1.5.0-beta.1" 1 "$(lib rl_cmp 1.5.0 1.5.0-beta.1)"

# =================================================================================
section "version.sh: highest tag at HEAD wins"
new_sandbox vsh
desc() { (cd "$R" && bash -c 'source scripts/version.sh; echo "$SNAPPY_VERSION $SNAPPY_DESCRIPTION"'); }
echo a >"$R/a"; g add a; g commit -q -m a
g tag v1.5.0                                  # lightweight stable
g tag -a v1.5.0-beta.3 -m "beta 3"            # annotated beta, same commit
eq "lightweight stable + annotated beta on one commit -> stable" "1.5.0 1.5.0" "$(desc)"
echo b >"$R/b"; g add b; g commit -q -m b
g tag v1.4.9                                  # older lightweight
g tag -a v1.6.0-beta.1 -m "beta 1"
eq "older lightweight tag cannot shadow the annotated beta" "1.6.0 1.6.0-beta.1" "$(desc)"
echo c >"$R/c"; g add c; g commit -q -m c
case $(desc) in "1.6.0 1.6.0-beta.1-1-g"*) ok "one commit later: describe" ;; *) bad "one commit later: describe" "$(desc)" ;; esac
g reset -q --hard HEAD~1
echo dirty >>"$R/a"
eq "dirty tree on a tag -> -dirty" "1.6.0 1.6.0-beta.1-dirty" "$(desc)"

# =================================================================================
section "update-tap.sh: bump rules"
new_sandbox tap
SUM_A=$(printf 'a%.0s' $(seq 64))
tap() { (cd "$R" && ./scripts/update-tap.sh "$@"); }
tapstate() { echo "$(cask_ver snappy)|$(cask_ver snappy@beta)"; }
while read -r v want; do
    succeeds "update-tap $v" tap "$v" "$SUM_A"
    eq "  casks after $v (stable|beta)" "$want" "$(tapstate)"
done <<'EOF'
1.1.0-beta.1 1.0.0|1.1.0-beta.1
1.1.0-beta.2 1.0.0|1.1.0-beta.2
1.0.1 1.0.1|1.1.0-beta.2
1.1.0 1.1.0|1.1.0
1.2.0-beta.1 1.1.0|1.2.0-beta.1
1.1.1 1.1.1|1.2.0-beta.1
EOF
N_BEFORE=$(git -C "$TAPGIT" rev-list --count main)
succeeds "patch to an older line (1.0.2)" tap 1.0.2 "$SUM_A"
has "  reports no change" "no cask change" "$OUT"
eq "  neither cask updated, no tap commit" "1.1.1|1.2.0-beta.1 $N_BEFORE" "$(tapstate) $(git -C "$TAPGIT" rev-list --count main)"
has "rendered sha256" "sha256 \"$SUM_A\"" "$(git -C "$TAPGIT" show main:Casks/snappy.rb)"
has "stable cask conflicts with beta" 'conflicts_with cask: "snappy@beta"' "$(git -C "$TAPGIT" show main:Casks/snappy.rb)"
has "beta cask token" 'cask "snappy@beta"' "$(git -C "$TAPGIT" show main:Casks/snappy@beta.rb)"
has "brew style ran" "brew style" "$(cat "$BREW_LOG")"
has "brew audit by token" "brew audit --cask --strict tefa-m/snappy/snappy@beta" "$(cat "$BREW_LOG")"
succeeds "--plan" tap --plan 1.3.0
has "  --plan shows both bumps" "snappy: 1.1.1 -> 1.3.0" "$OUT"
eq "  --plan changes nothing" "1.1.1|1.2.0-beta.1" "$(tapstate)"
echo junk >"$TAP/junk"
fails "dirty tap refused" "uncommitted changes" tap 1.3.0 "$SUM_A"
rm "$TAP/junk"
fails "brew style failure stops the bump" "brew style failed" env BREW_STYLE_RC=1 bash -c "cd '$R' && ./scripts/update-tap.sh 1.3.0 $SUM_A"
eq "  tap untouched after style failure" "1.1.1|1.2.0-beta.1 " "$(tapstate) $(git -C "$TAP" status --porcelain)"
fails "bad sha256 rejected" "sha256" tap 1.3.0 abc

# =================================================================================
section "release.sh: betas, dry run, stable promotion"
new_sandbox flow
fails "beta with nothing new since v1.0.0" "nothing new" rel beta --yes
A=$(merge_feature alpha)
: >"$GH_STATE/log"; : >"$BREW_LOG"
TAP_HEAD=$(git -C "$TAPGIT" rev-parse main)
succeeds "beta --dry-run" rel beta --dry-run
has "  plan names 1.1.0-beta.1" "1.1.0-beta.1  (beta)" "$OUT"
has "  notes preview lists the merge" "- Merge feat/alpha: alpha" "$OUT"
eq "  dry run: no local tag" no "$(local_tag v1.1.0-beta.1 && echo yes || echo no)"
eq "  dry run: no remote tag" no "$(remote_tag v1.1.0-beta.1 && echo yes || echo no)"
eq "  dry run: gh never called" "" "$(cat "$GH_STATE/log")"
hasnt "  dry run: no brew style/audit" "brew" "$(cat "$BREW_LOG")"
eq "  dry run: tap unchanged" "$TAP_HEAD" "$(git -C "$TAPGIT" rev-parse main)"
eq "  dry run: no worktree left" 1 "$(g worktree list | wc -l | tr -d ' ')"
fails "non-TTY without --yes refused" "--yes" rel beta
eq "  refused: no tag" no "$(local_tag v1.1.0-beta.1 && echo yes || echo no)"
fails "red test gate stops the release" "tests failed" env SNAPPY_RELEASE_TEST_CMD=false bash -c "cd '$R' && ./scripts/release.sh beta --yes </dev/null"
eq "  red tests: no tag" no "$(local_tag v1.1.0-beta.1 && echo yes || echo no)"

succeeds "beta -> v1.1.0-beta.1" rel beta --yes
eq "  tag on origin is annotated" tag "$(git -C "$O" cat-file -t v1.1.0-beta.1 2>&1)"
eq "  tag points at origin/main" "$(g rev-parse origin/main)" "$(git -C "$O" rev-parse 'v1.1.0-beta.1^{commit}')"
eq "  release published" false "$(cat "$GH_STATE/v1.1.0-beta.1/isDraft")"
has "  created as draft" "--draft" "$(cat "$GH_STATE/v1.1.0-beta.1/create-flags")"
has "  published as pre-release" "--prerelease" "$(cat "$GH_STATE/v1.1.0-beta.1/edit-flags")"
has "  asset downloaded back for verification" "--pattern Snappy-1.1.0-beta.1.zip" "$(cat "$GH_STATE/log")"
NOTES=$(cat "$GH_STATE/v1.1.0-beta.1/notes.md")
has "  notes: change list" "- Merge feat/alpha: alpha" "$NOTES"
has "  notes: compare link" "https://github.com/sandbox/snappy/compare/v1.0.0...v1.1.0-beta.1" "$NOTES"
has "  notes: beta install" "brew install --cask tefa-m/snappy/snappy@beta" "$NOTES"
has "  notes: pre-release warning" "Pre-release, may be unstable" "$NOTES"
has "  notes: sha256" "$(shasum -a 256 "$GH_STATE/v1.1.0-beta.1/Snappy-1.1.0-beta.1.zip" | cut -d' ' -f1)" "$NOTES"
eq "  tap: beta cask created, stable untouched" "1.0.0|1.1.0-beta.1" "$(tapstate)"
fails "same version again refused" "already exists" rel 1.1.0-beta.1 --yes

B=$(merge_feature bravo)
fails "beta major while the 1.1.0 train is open" "train v1.1.0 is open" rel beta major --dry-run
fails "explicit beta must be the next number" "beta.2, not beta.5" rel 1.1.0-beta.5 --dry-run
fails "explicit beta.0 is invalid" "usage" rel 1.1.0-beta.0 --dry-run
succeeds "beta minor -> next in the open train" rel beta minor --yes
eq "  v1.1.0-beta.2 on origin" yes "$(remote_tag v1.1.0-beta.2 && echo yes || echo no)"
has "  notes since the previous beta only" "compare/v1.1.0-beta.1...v1.1.0-beta.2" "$(cat "$GH_STATE/v1.1.0-beta.2/notes.md")"
hasnt "  notes exclude the previous beta's changes" "feat/alpha" "$(cat "$GH_STATE/v1.1.0-beta.2/notes.md")"
eq "  open train detected" 1.1.0 "$(lib rl_open_train)"

C=$(merge_feature charlie)
fails "stable refused: origin/main is not the latest beta's commit" "is not the commit of v1.1.0-beta.2" rel stable --yes
succeeds "stable allowed with SNAPPY_RELEASE_ALLOW_UNBETAED=1 (dry run)" env SNAPPY_RELEASE_ALLOW_UNBETAED=1 bash -c "cd '$R' && ./scripts/release.sh stable --dry-run </dev/null"
has "  plans 1.1.0" "1.1.0  (stable)" "$OUT"
succeeds "beta -> v1.1.0-beta.3" rel beta --yes
succeeds "stable -> v1.1.0 (on the latest beta's commit)" rel stable "Big headline" --yes
eq "  stable tag on the beta.3 commit" "$(g rev-parse 'v1.1.0-beta.3^{commit}')" "$(git -C "$O" rev-parse 'v1.1.0^{commit}')"
has "  published --latest" "--latest" "$(cat "$GH_STATE/v1.1.0/edit-flags")"
hasnt "  not a pre-release" "--prerelease" "$(cat "$GH_STATE/v1.1.0/edit-flags")"
NOTES=$(cat "$GH_STATE/v1.1.0/notes.md")
has "  notes: headline" "Big headline" "$NOTES"
has "  notes: all merges since v1.0.0" "- Merge feat/charlie: charlie" "$NOTES"
has "  notes: alpha too" "- Merge feat/alpha: alpha" "$NOTES"
has "  notes: pre-release links" "- [v1.1.0-beta.1](https://github.com/sandbox/snappy/releases/tag/v1.1.0-beta.1)" "$NOTES"
has "  notes: beta.3 listed" "v1.1.0-beta.3" "$NOTES"
has "  notes: compare from the last stable" "compare/v1.0.0...v1.1.0" "$NOTES"
has "  notes: stable install" "brew install --cask tefa-m/snappy/snappy\`" "$NOTES"
hasnt "  notes: no pre-release warning" "may be unstable" "$NOTES"
eq "  tap: both casks at 1.1.0" "1.1.0|1.1.0" "$(tapstate)"
eq "  no open train after promotion" "" "$(lib rl_open_train)"
fails "stable with no open train" "no open beta train" rel stable --yes

# =================================================================================
section "backport.sh + patch releases + provenance gate"
fails "patch with no release branch" "release branches" rel patch --yes
D=$(merge_feature delta-fix)
g switch -q -c side; echo s >"$R/s"; g add s; g commit -q -m side; SIDE=$(g rev-parse HEAD); g switch -q main
fails "backport refuses a commit not on origin/main" "is not on origin/main" bp 1.1 "$SIDE"
succeeds "backport 1.1 <merge> (no push)" bp 1.1 "$D"
has "  next steps mention release.sh patch" "release.sh patch" "$OUT"
eq "  release/1.1 created from v1.1.0" "$(g rev-parse v1.1.0^{commit})" "$(g rev-parse release/1.1~1)"
eq "  not pushed without --push" no "$(git -C "$O" rev-parse -q --verify refs/heads/release/1.1 >/dev/null && echo yes || echo no)"
has "  pick carries the -x trailer" "(cherry picked from commit $D)" "$(g log -1 --format=%B release/1.1)"
eq "  user's checkout untouched" main "$(g branch --show-current)"
fails "patch before the branch is pushed" "origin/release/1.1 does not exist" rel 1.1.1 --dry-run
g push -q -u origin release/1.1
g switch -q release/1.1
fails "explicit patch must be the next one" "the next patch of 1.1 is 1.1.1" rel 1.1.3 --dry-run
succeeds "patch -> v1.1.1 from release/1.1 (provenance gate passes for -x -m 1 picks)" rel patch --yes
g switch -q main
eq "  v1.1.1 on release/1.1" "$(g rev-parse origin/release/1.1)" "$(git -C "$O" rev-parse 'v1.1.1^{commit}')"
eq "  v1.1.1 not reachable from main" no "$(g merge-base --is-ancestor v1.1.1 origin/main && echo yes || echo no)"
has "  published --latest (highest stable)" "--latest" "$(cat "$GH_STATE/v1.1.1/edit-flags")"
has "  patch notes: picked subject" "- Merge feat/delta-fix: delta-fix" "$(cat "$GH_STATE/v1.1.1/notes.md")"
has "  patch notes: compare link" "compare/v1.1.0...v1.1.1" "$(cat "$GH_STATE/v1.1.1/notes.md")"
eq "  tap: both casks at 1.1.1" "1.1.1|1.1.1" "$(tapstate)"
fails "patch with nothing new on release/1.1" "nothing new" rel 1.1.2 --dry-run
fails "patch of a line without a branch" "origin/release/1.2 does not exist" rel 1.2.1 --dry-run

E=$(merge_feature echo)
succeeds "beta after a patch: new train from the latest stable -> 1.2.0-beta.1" rel beta --yes
eq "  v1.2.0-beta.1 on origin" yes "$(remote_tag v1.2.0-beta.1 && echo yes || echo no)"
has "  beta.1 notes since the reachable stable v1.1.0" "compare/v1.1.0...v1.2.0-beta.1" "$(cat "$GH_STATE/v1.2.0-beta.1/notes.md")"
succeeds "stable -> v1.2.0" rel stable --yes
NOTES=$(cat "$GH_STATE/v1.2.0/notes.md")
CHANGES=$(printf '%s\n' "$NOTES" | sed -n '/^## Changes/,/^## /p')
has "  notes: new merge listed" "- Merge feat/echo: echo" "$CHANGES"
hasnt "  notes dedupe: back-ported fix not in Changes" "delta-fix" "$CHANGES"
has "  notes dedupe: marked (also in 1.1.1)" "- Merge feat/delta-fix: delta-fix (also in 1.1.1)" "$NOTES"
eq "  tap: both casks at 1.2.0" "1.2.0|1.2.0" "$(tapstate)"

F=$(merge_feature foxtrot-fix)
succeeds "backport 1.1 <merge> --push" bp 1.1 "$F" --push
eq "  pushed" "$(g rev-parse release/1.1)" "$(git -C "$O" rev-parse refs/heads/release/1.1)"
succeeds "patch 1.1.2 to an older line" rel 1.1.2 --yes
has "  published --latest=false" "--latest=false" "$(cat "$GH_STATE/v1.1.2/edit-flags")"
eq "  tap: neither cask touched" "1.2.0|1.2.0" "$(tapstate)"

BR_BEFORE=$(g rev-parse release/1.1)
g switch -q -c feat/readme1; echo one >"$R/README"; g commit -q -am "README one"; g switch -q main
g merge -q --no-ff -m "Merge feat/readme1" feat/readme1
g switch -q -c feat/readme2; echo two >"$R/README"; g commit -q -am "README two"; g switch -q main
g merge -q --no-ff -m "Merge feat/readme2" feat/readme2
g push -q origin main
fails "backport conflict aborts cleanly" "conflicts" bp 1.1 "$(g rev-parse HEAD)"
eq "  release/1.1 unchanged after the conflict" "$BR_BEFORE" "$(g rev-parse release/1.1)"
eq "  no worktree left" 1 "$(g worktree list | wc -l | tr -d ' ')"
fails "backport with red tests rolls back" "tests failed" env SNAPPY_RELEASE_TEST_CMD=false bash -c "cd '$R' && ./scripts/backport.sh 1.1 $(g rev-parse HEAD~1) </dev/null"
eq "  release/1.1 unchanged after red tests" "$BR_BEFORE" "$(g rev-parse release/1.1)"

g switch -q release/1.1
echo hotfix >"$R/hotfix"; g add hotfix; g commit -q -m "Direct hotfix on the release branch"
g push -q origin release/1.1
fails "patch refused: direct hotfix fails the provenance gate" "Direct hotfix on the release branch" rel patch --yes
has "  gate names itself" "Provenance gate FAILED" "$OUT"
g switch -q main
G=$(merge_feature golf)
fails "beta on main refused too while a release branch has a direct hotfix" "Provenance gate FAILED" rel beta --dry-run
eq "  nothing tagged" no "$(local_tag v1.3.0-beta.1 && echo yes || echo no)"

# =================================================================================
section "release.sh: atomic push, failure before push, --resume"
new_sandbox push
merge_feature alpha >/dev/null
cat >"$O/hooks/pre-receive" <<'EOF'
#!/bin/sh
while read old new ref; do
  case $ref in refs/tags/*) echo "hook: tags rejected" >&2; exit 1 ;; esac
done
EOF
chmod +x "$O/hooks/pre-receive"
: >"$GH_STATE/log"
MAIN_BEFORE=$(git -C "$O" rev-parse main)
fails "push rejected by origin" "push failed" rel beta --yes
eq "  local tag deleted" no "$(local_tag v1.1.0-beta.1 && echo yes || echo no)"
eq "  no remote tag" no "$(remote_tag v1.1.0-beta.1 && echo yes || echo no)"
eq "  origin main unchanged" "$MAIN_BEFORE" "$(git -C "$O" rev-parse main)"
eq "  gh never called" "" "$(cat "$GH_STATE/log")"
rm "$O/hooks/pre-receive"

fails "gh fails after the push" "--resume 1.1.0-beta.1" env GH_FAIL_CREATE=1 bash -c "cd '$R' && ./scripts/release.sh beta --yes </dev/null"
eq "  tag stays on origin (never re-tagged)" yes "$(remote_tag v1.1.0-beta.1 && echo yes || echo no)"
eq "  local tag kept" yes "$(local_tag v1.1.0-beta.1 && echo yes || echo no)"
fails "a plain re-run refuses" "already exists on origin" rel 1.1.0-beta.1 --yes
fails "resume without the tag on origin" "not on origin" rel --resume 1.1.0-beta.9 --yes
succeeds "--resume finishes the release" rel --resume 1.1.0-beta.1 --yes
eq "  published" false "$(cat "$GH_STATE/v1.1.0-beta.1/isDraft")"
has "  pre-release" "--prerelease" "$(cat "$GH_STATE/v1.1.0-beta.1/edit-flags")"
eq "  tap updated" "1.0.0|1.1.0-beta.1" "$(tapstate)"
succeeds "--resume of a published release is idempotent" rel --resume 1.1.0-beta.1 --yes
has "  tap: no change" "no cask change" "$OUT"

# =================================================================================
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
