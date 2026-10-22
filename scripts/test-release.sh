#!/bin/bash
# Sandbox tests for the release tooling (release.sh, backport.sh, update-tap.sh,
# version.sh, lib/release-lib.sh, hooks/commit-msg). Run with macOS /bin/bash (3.2):
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
tag="" pos="" pattern="" dir="" notes="" flags="" json=""
while [ $# -gt 0 ]; do
    case $1 in
        -R | --jq) shift 2 ;;
        --json) json=$2; shift 2 ;;
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
    view)
        [ -d "$d" ] || { echo "release not found" >&2; exit 1; }
        if [ "$json" = body ]; then cat "$d/notes.md"; else cat "$d/isDraft"; fi ;;
    create)
        [ -z "${GH_FAIL_CREATE:-}" ] || { echo "gh shim: simulated create failure" >&2; exit 1; }
        [ ! -d "$d" ] || { echo "release exists" >&2; exit 1; }
        mkdir -p "$d"; echo true >"$d/isDraft"; cp "$pos" "$d/"; cp "$notes" "$d/notes.md"; echo "$flags" >"$d/create-flags" ;;
    upload) cp "$pos" "$d/" ;;
    download) [ -f "$d/$pattern" ] || exit 1; cp "$d/$pattern" "$dir/" ;;
    edit)
        [ -z "$notes" ] || cp "$notes" "$d/notes.md"
        case $flags in
            *--draft=false*)
                [ -z "${GH_FAIL_PUBLISH:-}" ] || { echo "gh shim: simulated publish failure" >&2; exit 1; }
                echo false >"$d/isDraft"; echo "$flags" >"$d/edit-flags" ;;
        esac ;;
    *) exit 1 ;;
esac
EOF
cat >"$T/bin/brew" <<'EOF'
#!/bin/bash
echo "brew $*" >>"$BREW_LOG"
case $1 in
    style) # BREW_STYLE_BARRIER=<path>: signal <path>.in, wait (bounded) for <path>.go
        if [ -n "${BREW_STYLE_BARRIER:-}" ]; then
            : >"$BREW_STYLE_BARRIER.in"; i=0
            while [ ! -e "$BREW_STYLE_BARRIER.go" ] && [ $i -lt 600 ]; do sleep 0.05; i=$((i + 1)); done
        fi
        exit "${BREW_STYLE_RC:-0}" ;;
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
        "$SRC/scripts/version.sh" "$SRC/scripts/lib" "$SRC/scripts/templates" "$SRC/scripts/hooks" "$R/scripts/"
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
# merge_feature <name> [subject] — a --no-ff feature merge on main, pushed;
# prints its sha. Default subject: the legacy "Merge feat/<name>: <name>".
merge_feature() {
    g switch -q main
    g switch -q -c "feat/$1"
    echo "$1" >"$R/$1.txt"; g add "$1.txt"; g commit -q -m "Add $1"
    g switch -q main
    g merge -q --no-ff -m "${2:-Merge feat/$1: $1}" "feat/$1"
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
# notes_sec <heading> <notes> — the non-blank lines under "## <heading>".
notes_sec() { printf '%s\n' "$2" | awk -v h="## $1" '$0 == h { on = 1; next } on && (/^## / || /^---/) { exit } on && NF { print }'; }
NL=$'\n'
WARN_UNCONV="do not follow '<type>: <summary>'"

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
fails "same version with another sha256 refused" "different sha256" tap 1.1.1 "$(printf 'b%.0s' $(seq 64))"

section "update-tap.sh: beta cask never below the stable cask (M4)"
new_sandbox tapbeta
sed -e 's/@@VERSION@@/0.9.0/' -e "s/@@SHA256@@/$SUM_A/" "$SRC/scripts/templates/snappy@beta.rb.tmpl" >"$TAP/Casks/snappy@beta.rb"
git -C "$TAP" add -A && git -C "$TAP" commit -q -m "stale beta cask" && git -C "$TAP" push -q origin main
succeeds "--plan 1.0.0 with no newer version" tap --plan 1.0.0
has "  beta cask unchanged" "snappy@beta: unchanged" "$OUT"
succeeds "older-line patch 0.9.1 with a stale existing beta cask 0.9.0" tap 0.9.1 "$SUM_A"
eq "  neither cask updated" "1.0.0|0.9.0" "$(tapstate)"
succeeds "newer stable patch 1.0.1 moves both casks" tap 1.0.1 "$SUM_A"
eq "  both casks at 1.0.1" "1.0.1|1.0.1" "$(tapstate)"
git -C "$TAP" rm -q Casks/snappy@beta.rb && git -C "$TAP" commit -q -m "drop beta cask" && git -C "$TAP" push -q origin main
succeeds "--plan 1.0.1 (equal to stable) with the beta cask missing" tap --plan 1.0.1
has "  missing beta cask not created" "snappy@beta: unchanged (missing)" "$OUT"
succeeds "--plan 1.0.2 with the beta cask missing" tap --plan 1.0.2
has "  missing beta cask created above stable" "snappy@beta: new -> 1.0.2" "$OUT"

section "update-tap.sh: a failed tap push is reconciled on retry (M3)"
cat >"$TAPGIT/hooks/pre-receive" <<'EOF'
#!/bin/sh
echo "hook: tap push rejected" >&2; exit 1
EOF
chmod +x "$TAPGIT/hooks/pre-receive"
fails "tap push rejected" "pushing the tap failed" tap 1.1.0 "$SUM_A"
eq "  remote casks unchanged" "1.0.1|" "$(tapstate)"
eq "  commit left local (ahead 1)" 1 "$(git -C "$TAP" rev-list --count origin/main..main)"
MARK="$TAP/.git/snappy-pending-release"
has "  marker records the commit" "commit $(git -C "$TAP" rev-parse HEAD)" "$(cat "$MARK" 2>&1)"
fails "retry while the push is still rejected fails loudly" "still stale" tap 1.1.0 "$SUM_A"
hasnt "  no success claimed" "no cask change" "$OUT"
eq "  marker survives a second failing push" "commit $(git -C "$TAP" rev-parse HEAD)" "$(head -n 1 "$MARK" 2>&1)"
rm "$TAPGIT/hooks/pre-receive"
succeeds "retry pushes the pending commit" tap 1.1.0 "$SUM_A"
has "  reports the pending push" "pushing the pending cask commit" "$OUT"
eq "  remote casks now at 1.1.0" "1.1.0|1.1.0" "$(tapstate)"
eq "  local main == origin/main" "$(git -C "$TAPGIT" rev-parse main)" "$(git -C "$TAP" rev-parse main)"
eq "  marker cleared after the verified push" no "$([ -e "$MARK" ] && echo yes || echo no)"
echo note >"$TAP/NOTE"; git -C "$TAP" add NOTE; git -C "$TAP" commit -q -m "local note"
fails "a foreign local commit is not pushed" "did not make" tap 1.2.0 "$SUM_A"
eq "  remote untouched" "1.1.0|1.1.0" "$(tapstate)"
git -C "$TAP" reset -q --hard origin/main

section "update-tap.sh: only a recorded pending commit is pushed (N1)"
new_sandbox pending
MARK="$TAP/.git/snappy-pending-release"
remote_head() { git -C "$TAPGIT" rev-parse main; }
H0=$(remote_head)
printf '\n# unrelated local cask work (unreviewed)\n' >>"$TAP/Casks/snappy.rb"
git -C "$TAP" add Casks/snappy.rb && git -C "$TAP" commit -q -m 'Snappy 1.0.0: snappy'
fails "hand-made release-shaped cask commit is not pushed" "did not make" tap 0.9.1 "$SUM_A"
has "  explains manual recovery" "reset --hard origin/main" "$OUT"
eq "  remote untouched" "$H0" "$(remote_head)"
git -C "$TAP" reset -q --hard origin/main
echo x >"$TAP/UNRELATED"; git -C "$TAP" add UNRELATED; git -C "$TAP" commit -q -m 'Snappy 1.0.0: snappy'
git -C "$TAP" rm -q UNRELATED; git -C "$TAP" commit -q -m 'Snappy 1.0.0: snappy@beta'
fails "net-zero release-shaped history is not pushed" "did not make" tap 0.9.1 "$SUM_A"
eq "  remote untouched" "$H0" "$(remote_head)"
git -C "$TAP" reset -q --hard origin/main
cat >"$TAPGIT/hooks/pre-receive" <<'HOOK'
#!/bin/sh
exit 1
HOOK
chmod +x "$TAPGIT/hooks/pre-receive"
fails "push rejected leaves a pending commit" "pushing the tap failed" tap 1.1.0 "$SUM_A"
rm "$TAPGIT/hooks/pre-receive"
P=$(git -C "$TAP" rev-parse HEAD)
cp "$MARK" "$TAP/.git/marker.bak"
git -C "$TAP" commit -q --amend -m "Snappy 1.1.0: snappy snappy@beta (amended)"
fails "amended pending commit refused" "did not make" tap 1.1.0 "$SUM_A"
has "  stale marker warned about" "stale tap marker" "$OUT"
eq "  stale marker removed" no "$([ -e "$MARK" ] && echo yes || echo no)"
eq "  remote untouched" "$H0" "$(remote_head)"
git -C "$TAP" reset -q --hard "$P"
sed 's/^\(file Casks\/snappy.rb \).*/\1'"$(printf '0%.0s' $(seq 64))"'/' "$TAP/.git/marker.bak" >"$MARK"
fails "pending commit with a changed cask hash refused" "no longer matches" tap 1.1.0 "$SUM_A"
eq "  remote untouched" "$H0" "$(remote_head)"
git -C "$TAP" reset -q --hard origin/main
printf 'commit %s\nversion 1.1.0\nfile Casks/snappy.rb %s\n' "$P" "$SUM_A" >"$MARK"
succeeds "marker for a commit no longer on main is ignored" tap --plan 1.1.0
succeeds "  ... and a normal run proceeds" tap 1.1.0 "$SUM_A"
has "  with a stale-marker warning" "stale tap marker" "$OUT"
eq "  casks published" "1.1.0|1.1.0" "$(tapstate)"
eq "  no marker left after a verified push" no "$([ -e "$MARK" ] && echo yes || echo no)"
git -C "$TAP" commit -q --allow-empty -m "Snappy 1.2.0: snappy"
printf 'commit %s\nversion 1.2.0\nfile Casks/snappy.rb %s\n' "$(git -C "$TAP" rev-parse HEAD^)" "$SUM_A" >"$MARK"
H1=$(remote_head)
fails "extra commit on top of a recorded one refused" "did not make" tap 1.2.0 "$SUM_A"
eq "  remote untouched" "$H1" "$(remote_head)"
git -C "$TAP" reset -q --hard origin/main; rm -f "$MARK"

section "update-tap.sh: one run per tap at a time (C1)"
new_sandbox lock
LOCK="$TAP/.git/snappy-update-tap.lock"
SUM_B=$(printf 'b%.0s' $(seq 64))
lockgone() { [ -e "$LOCK" ] && echo held || echo released; }
wait_file() { local i=0; while [ ! -e "$1" ] && [ $i -lt 400 ]; do sleep 0.05; i=$((i + 1)); done; [ -e "$1" ]; }
# start_held <barrier> <dir> <args...> — update-tap in <dir> in the background, parked in brew style
start_held() {
    local b=$1 d=$2; shift 2; rm -f "$b.in" "$b.go"
    (cd "$d" && BREW_STYLE_BARRIER=$b exec ./scripts/update-tap.sh "$@") >"$b.out" 2>&1 &
    HELD=$!
    wait_file "$b.in" || bad "background run never reached brew style" "$(cat "$b.out")"
}
B="$T/lock/bar"
H0=$(git -C "$TAPGIT" rev-parse main)
start_held "$B" "$R" 1.1.0 "$SUM_A"
OWNER=$(sed -n 's/^pid //p' "$LOCK/owner")
eq "  lock owned by the running update (A)" "$HELD" "$OWNER"
CASKS=$(cat "$TAP"/Casks/*.rb | shasum)
fails "overlapping run (B) fails loudly" "holds the tap lock" tap 1.2.0 "$SUM_B"
has "  names the owner pid" "pid $OWNER" "$OUT"
has "  names the lock path" "$LOCK" "$OUT"
eq "  origin untouched by B" "$H0" "$(git -C "$TAPGIT" rev-parse main)"
eq "  A's rendered casks untouched by B" "$CASKS" "$(cat "$TAP"/Casks/*.rb | shasum)"
touch "$B.go"; wait "$HELD"; RC=$?
eq "  A completes" 0 "$RC"
has "  A published its own version" "committed and pushed Snappy 1.1.0" "$(cat "$B.out")"
eq "  origin carries 1.1.0 with A's sha256 in both casks" "1.1.0|1.1.0 2" "$(tapstate) $(git -C "$TAPGIT" show main:Casks/snappy.rb main:Casks/snappy@beta.rb | grep -c "sha256 \"$SUM_A\"")"
eq "  lock released after success" released "$(lockgone)"
fails "style failure" "brew style failed" env BREW_STYLE_RC=1 bash -c "cd '$R' && ./scripts/update-tap.sh 1.3.0 $SUM_A"
eq "  lock released after failure" released "$(lockgone)"
start_held "$B" "$R" 1.4.0 "$SUM_A"
kill -TERM "$HELD"; touch "$B.go"; wait "$HELD"; RC=$?
eq "  SIGTERM: run exits 143" 143 "$RC"
eq "  lock released after SIGTERM" released "$(lockgone)"
eq "  rendered casks rolled back after SIGTERM" "1.1.0|1.1.0 " "$(tapstate) $(git -C "$TAP" status --porcelain)"
eq "  origin unchanged by the killed run" "1.1.0|1.1.0" "$(tapstate)"
sh -c 'exit 0' & DEAD=$!; wait "$DEAD"
mkdir "$LOCK"; printf 'pid %s\nstart Thu Jan  1 00:00:00 1970\n' "$DEAD" >"$LOCK/owner"
succeeds "stale lock (dead owner) is taken over" tap 1.2.0 "$SUM_A"
has "  with a warning" "taking over the stale tap lock" "$OUT"
eq "  casks published" "1.2.0|1.2.0" "$(tapstate)"
eq "  lock released afterwards" released "$(lockgone)"
mkdir "$LOCK"; printf 'pid %s\nstart Thu Jan  1 00:00:00 1970\n' $$ >"$LOCK/owner"
succeeds "stale lock (pid reused by another process) is taken over" tap --plan 1.3.0
has "  with a warning" "taking over the stale tap lock" "$OUT"
mkdir "$LOCK"
fails "lock without an owner record is not taken over" "holds the tap lock" tap --plan 1.3.0
rm -rf "$LOCK"
WT="$T/lock/tap-wt"
git -C "$TAP" switch -q -c side; git -C "$TAP" worktree add -q "$WT" main
SNAPPY_TAP_DIR="$WT" start_held "$B" "$R" 1.3.0 "$SUM_A"
fails "linked worktree tap: run in the main clone is refused while one runs" "holds the tap lock" env SNAPPY_TAP_DIR="$TAP" bash -c "cd '$R' && ./scripts/update-tap.sh 1.4.0 $SUM_A"
touch "$B.go"; wait "$HELD"; RC=$?
eq "  the worktree run completes" 0 "$RC"
eq "  ... and published 1.3.0" "1.3.0|1.3.0" "$(tapstate)"
eq "  shared lock released" released "$(lockgone)"

# =================================================================================
section "release.sh: betas, dry run, stable promotion"
new_sandbox flow
fails "beta with nothing new since v1.0.0" "nothing new" rel beta --yes
A=$(merge_feature alpha "feat: alpha")
: >"$GH_STATE/log"; : >"$BREW_LOG"
TAP_HEAD=$(git -C "$TAPGIT" rev-parse main)
succeeds "beta --dry-run" rel beta --dry-run
has "  plan names 1.1.0-beta.1" "1.1.0-beta.1  (beta)" "$OUT"
eq "  notes preview: feat under Features, prefix stripped" "- alpha" "$(notes_sec Features "$OUT")"
hasnt "  all subjects conventional: no warning" "$WARN_UNCONV" "$OUT"
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
eq "  notes: Features" "- alpha" "$(notes_sec Features "$NOTES")"
hasnt "  notes: no Other changes" "## Other changes" "$NOTES"
hasnt "  notes: no type prefix" "feat:" "$NOTES"
has "  notes: compare link" "https://github.com/sandbox/snappy/compare/v1.0.0...v1.1.0-beta.1" "$NOTES"
has "  notes: beta install" "brew install --cask tefa-m/snappy/snappy@beta" "$NOTES"
has "  notes: pre-release warning" "Pre-release, may be unstable" "$NOTES"
has "  notes: sha256" "$(shasum -a 256 "$GH_STATE/v1.1.0-beta.1/Snappy-1.1.0-beta.1.zip" | cut -d' ' -f1)" "$NOTES"
eq "  tap: beta cask created, stable untouched" "1.0.0|1.1.0-beta.1" "$(tapstate)"
fails "same version again refused" "already exists" rel 1.1.0-beta.1 --yes

B=$(merge_feature bravo "fix: bravo")
fails "beta major while the 1.1.0 train is open" "train v1.1.0 is open" rel beta major --dry-run
fails "explicit beta must be the next number" "beta.2, not beta.5" rel 1.1.0-beta.5 --dry-run
fails "explicit beta.0 is invalid" "usage" rel 1.1.0-beta.0 --dry-run
succeeds "beta minor -> next in the open train" rel beta minor --yes
eq "  v1.1.0-beta.2 on origin" yes "$(remote_tag v1.1.0-beta.2 && echo yes || echo no)"
has "  notes since the previous beta only" "compare/v1.1.0-beta.1...v1.1.0-beta.2" "$(cat "$GH_STATE/v1.1.0-beta.2/notes.md")"
hasnt "  notes exclude the previous beta's changes" "alpha" "$(cat "$GH_STATE/v1.1.0-beta.2/notes.md")"
eq "  notes: fix under Fixes" "- bravo" "$(notes_sec Fixes "$(cat "$GH_STATE/v1.1.0-beta.2/notes.md")")"
hasnt "  notes: no empty Features group" "## Features" "$(cat "$GH_STATE/v1.1.0-beta.2/notes.md")"
eq "  open train detected" 1.1.0 "$(lib rl_open_train)"

C=$(merge_feature charlie)
fails "stable refused: origin/main is not the latest beta's commit" "is not the commit of v1.1.0-beta.2" rel stable --yes
succeeds "stable allowed with SNAPPY_RELEASE_ALLOW_UNBETAED=1 (dry run)" env SNAPPY_RELEASE_ALLOW_UNBETAED=1 bash -c "cd '$R' && ./scripts/release.sh stable --dry-run </dev/null"
has "  plans 1.1.0" "1.1.0  (stable)" "$OUT"
succeeds "beta -> v1.1.0-beta.3" rel beta --yes
has "  warns about the unconventional subject" "$WARN_UNCONV" "$OUT"
has "  ... and names it" "           Merge feat/charlie: charlie" "$OUT"
eq "  release still published (warning only)" false "$(cat "$GH_STATE/v1.1.0-beta.3/isDraft")"
eq "  unconventional subject kept verbatim under Other changes" "- Merge feat/charlie: charlie" "$(notes_sec "Other changes" "$(cat "$GH_STATE/v1.1.0-beta.3/notes.md")")"
succeeds "stable -> v1.1.0 (on the latest beta's commit)" rel stable "Big headline" --yes
eq "  stable tag on the beta.3 commit" "$(g rev-parse 'v1.1.0-beta.3^{commit}')" "$(git -C "$O" rev-parse 'v1.1.0^{commit}')"
has "  published --latest" "--latest" "$(cat "$GH_STATE/v1.1.0/edit-flags")"
hasnt "  not a pre-release" "--prerelease" "$(cat "$GH_STATE/v1.1.0/edit-flags")"
NOTES=$(cat "$GH_STATE/v1.1.0/notes.md")
has "  notes: headline" "Big headline" "$NOTES"
eq "  notes: all merges since v1.0.0, grouped" "## Features|- alpha|## Fixes|- bravo|## Other changes|- Merge feat/charlie: charlie" \
    "$(printf '%s\n' "$NOTES" | sed -n '/^## Features/,/^## Pre-releases/p' | grep -v '^## Pre-releases' | grep . | tr '\n' '|' | sed 's/|$//')"
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
D=$(merge_feature delta-fix "fix: delta")
H=$(merge_feature hotel-chore "chore: hotel")
g switch -q -c side; echo s >"$R/s"; g add s; g commit -q -m side; SIDE=$(g rev-parse HEAD); g switch -q main
fails "backport refuses a commit not on origin/main" "is not on origin/main" bp 1.1 "$SIDE"
succeeds "backport 1.1 <merge> <merge> (no push)" bp 1.1 "$D" "$H"
has "  next steps mention release.sh patch" "release.sh patch" "$OUT"
eq "  release/1.1 created from v1.1.0" "$(g rev-parse v1.1.0^{commit})" "$(g rev-parse release/1.1~2)"
eq "  not pushed without --push" no "$(git -C "$O" rev-parse -q --verify refs/heads/release/1.1 >/dev/null && echo yes || echo no)"
has "  pick carries the -x trailer" "(cherry picked from commit $D)" "$(g log -1 --format=%B release/1.1~1)"
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
NOTES=$(cat "$GH_STATE/v1.1.1/notes.md")
eq "  patch notes (--no-merges picks): Fixes" "- delta" "$(notes_sec Fixes "$NOTES")"
hasnt "  patch notes: hidden chore pick" "hotel" "$NOTES"
has "  patch notes: compare link" "compare/v1.1.0...v1.1.1" "$(cat "$GH_STATE/v1.1.1/notes.md")"
eq "  tap: both casks at 1.1.1" "1.1.1|1.1.1" "$(tapstate)"
fails "patch with nothing new on release/1.1" "nothing new" rel 1.1.2 --dry-run
fails "patch of a line without a branch" "origin/release/1.2 does not exist" rel 1.2.1 --dry-run

E=$(merge_feature echo "feat: echo")
merge_feature india-docs "docs: india" >/dev/null
succeeds "beta after a patch: new train from the latest stable -> 1.2.0-beta.1" rel beta --yes
eq "  v1.2.0-beta.1 on origin" yes "$(remote_tag v1.2.0-beta.1 && echo yes || echo no)"
has "  beta.1 notes since the reachable stable v1.1.0" "compare/v1.1.0...v1.2.0-beta.1" "$(cat "$GH_STATE/v1.2.0-beta.1/notes.md")"
succeeds "stable -> v1.2.0" rel stable --yes
NOTES=$(cat "$GH_STATE/v1.2.0/notes.md")
eq "  notes: new merge listed" "- echo" "$(notes_sec Features "$NOTES")"
hasnt "  notes dedupe: back-ported fix not in Fixes" "## Fixes" "$NOTES"
hasnt "  notes: hidden docs merge" "india" "$NOTES"
eq "  notes dedupe: marked (also in 1.1.1), prefix stripped, hidden chore dropped" "- delta (also in 1.1.1)" \
    "$(notes_sec "Already shipped in patch releases" "$NOTES")"
eq "  tap: both casks at 1.2.0" "1.2.0|1.2.0" "$(tapstate)"

F=$(merge_feature foxtrot-fix)
succeeds "backport 1.1 <merge> --push" bp 1.1 "$F" --push
eq "  pushed" "$(g rev-parse release/1.1)" "$(git -C "$O" rev-parse refs/heads/release/1.1)"
succeeds "patch 1.1.2 to an older line" rel 1.1.2 --yes
has "  published --latest=false" "--latest=false" "$(cat "$GH_STATE/v1.1.2/edit-flags")"
eq "  legacy pick subject under Other changes" "- Merge feat/foxtrot-fix: foxtrot-fix" "$(notes_sec "Other changes" "$(cat "$GH_STATE/v1.1.2/notes.md")")"
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
section "release.sh --resume: dry run is read-only, verified asset, provenance (B1 M1 M2 M3)"
new_sandbox resume
merge_feature alpha >/dev/null
RV=1.1.0-beta.1 RT=v1.1.0-beta.1
# snap — everything a resume could mutate: origin refs, tap, local tags, gh state.
snap() {
    git -C "$O" for-each-ref --format='%(refname) %(objectname)'
    git -C "$TAPGIT" rev-parse main; git -C "$TAP" rev-parse main
    g for-each-ref --format='%(refname) %(objectname)' refs/tags
    (cd "$GH_STATE" && find . -type f ! -name log | sort | while read -r f; do shasum "$f"; done)
    grep -cE '^gh release (create|edit|upload|delete)' "$GH_STATE/log"
}
readonly_run() { # readonly_run <desc> <expect: ok|fail> <pattern> -- runs rel --resume $RV --dry-run
    local d=$1 want=$2 pat=$3 before
    before=$(snap)
    if [ "$want" = ok ]; then succeeds "$d" rel --resume "$RV" --dry-run; else fails "$d" "$pat" rel --resume "$RV" --dry-run; fi
    [ "$want" = fail ] || has "  says what it would do" "$pat" "$OUT"
    eq "  read-only (refs, tap, tags, gh state unchanged)" "$before" "$(snap)"
}

readonly_run "dry-run resume: tag not on origin" fail "not on origin"
fails "gh fails after the push (tag on origin, no release)" "--resume $RV" env GH_FAIL_CREATE=1 bash -c "cd '$R' && ./scripts/release.sh beta --yes </dev/null"
readonly_run "dry-run resume: no release yet" ok "gh release create $RT --draft"

g branch -q release/1.0 v1.0.0; g switch -q release/1.0
echo hotfix >"$R/hotfix"; g add hotfix; g commit -q -m "Direct hotfix on release/1.0"; g push -q origin release/1.0; g switch -q main
BEFORE=$(snap)
fails "resume refused by the provenance gate" "Provenance gate FAILED" rel --resume "$RV" --yes
has "  names the offending commit" "Direct hotfix on release/1.0" "$OUT"
eq "  nothing created or published" "$BEFORE" "$(snap)"
readonly_run "dry-run resume also runs the gate" fail "Provenance gate FAILED"
g push -q origin :release/1.0; g branch -q -D release/1.0

fails "resume interrupted at publish leaves a draft with its asset" "publishing the release failed" env GH_FAIL_PUBLISH=1 bash -c "cd '$R' && ./scripts/release.sh --resume $RV --yes </dev/null"
eq "  still a draft" true "$(cat "$GH_STATE/$RT/isDraft")"
GOOD=$(shasum -a 256 "$GH_STATE/$RT/Snappy-$RV.zip" | cut -d' ' -f1)
has "  draft notes record the asset's SHA-256" "$GOOD" "$(cat "$GH_STATE/$RT/notes.md")"
readonly_run "dry-run resume: draft with a verified asset" ok "reuse the draft asset (SHA-256 $GOOD"

echo corrupt >"$GH_STATE/$RT/Snappy-$RV.zip"
readonly_run "dry-run resume: tampered draft asset fails closed" fail "differs from the $GOOD recorded"
BEFORE=$(snap)
fails "resume refuses a tampered draft asset" "not publishing" rel --resume "$RV" --yes
eq "  not published, tap untouched" "$BEFORE" "$(snap)"

FAKE=$(printf 'f%.0s' $(seq 64))
rm "$GH_STATE/$RT/Snappy-$RV.zip"
sed -i '' "s/$GOOD/$FAKE/" "$GH_STATE/$RT/notes.md"   # the original build had another checksum
readonly_run "dry-run resume: draft without asset" ok "rebuild Snappy-$RV.zip"
cat >"$TAPGIT/hooks/pre-receive" <<'EOF'
#!/bin/sh
echo "hook: tap push rejected" >&2; exit 1
EOF
chmod +x "$TAPGIT/hooks/pre-receive"
fails "resume rebuilds the asset, publishes, tap push rejected" "pushing the tap failed" rel --resume "$RV" --yes
NOTES=$(cat "$GH_STATE/$RT/notes.md")
has "  notes now record the rebuilt SHA-256" "\`$GOOD\`" "$NOTES"
hasnt "  old recorded SHA-256 gone" "$FAKE" "$NOTES"
has "  notes rewritten via gh release edit --notes-file" "gh release edit -R sandbox/snappy $RT --notes-file" "$(cat "$GH_STATE/log")"
eq "  rebuilt asset uploaded" "$GOOD" "$(shasum -a 256 "$GH_STATE/$RT/Snappy-$RV.zip" | cut -d' ' -f1)"
eq "  published" false "$(cat "$GH_STATE/$RT/isDraft")"
eq "  remote tap still stale" "1.0.0|" "$(tapstate)"
rm "$TAPGIT/hooks/pre-receive"

readonly_run "dry-run resume: published release" ok "skip publishing ($RT is already published"
g branch -q release/1.0 v1.0.0; g switch -q release/1.0
echo hotfix2 >"$R/hotfix2"; g add hotfix2; g commit -q -m "Another direct hotfix"; g push -q origin release/1.0; g switch -q main
succeeds "resume of a published release repairs the tap (no provenance gate needed)" rel --resume "$RV" --yes
hasnt "  gate not run" "Provenance gate" "$OUT"
has "  pending tap commit pushed" "pushing the pending cask commit" "$OUT"
eq "  remote tap now has the beta cask" "1.0.0|$RV" "$(tapstate)"
has "  with the verified SHA-256" "sha256 \"$GOOD\"" "$(git -C "$TAPGIT" show main:Casks/snappy@beta.rb)"
g push -q origin :release/1.0; g branch -q -D release/1.0

# =================================================================================
section "release notes: subject convention, grouping, hidden types"
(
    source "$SRC/scripts/lib/release-lib.sh"
    while IFS='|' read -r subj want; do
        eq "parse '$subj'" "$want" "$(rl_parse_subject "$subj")"
    done <<'EOF'
feat: Pin windows remember their size|feat Pin windows remember their size
fix: fix: double prefix|fix fix: double prefix
perf: faster OCR|perf faster OCR
docs: shortcuts table|hidden shortcuts table
test: more cases|hidden more cases
chore: bump|hidden bump
build: universal zip|hidden universal zip
refactor: split module|hidden split module
Merge feat/x: legacy subject|other Merge feat/x: legacy subject
feat(ui): scopes are not supported|other feat(ui): scopes are not supported
feat!: no bang either|other feat!: no bang either
Feat: case matters|other Feat: case matters
feat:no space|other feat:no space
feature: unknown type|other feature: unknown type
EOF
    eq "grouped: order Features, Fixes, Performance, Other; hidden dropped; empty groups omitted" \
        "## Features${NL}${NL}- a${NL}- c${NL}${NL}## Fixes${NL}${NL}- f${NL}${NL}## Performance${NL}${NL}- p${NL}${NL}## Other changes${NL}${NL}- Merge branch 'x'" \
        "$(printf '%s\n' "perf: p" "feat: a" "docs: d" "Merge branch 'x'" "fix: f" "" "feat: c" "chore: h" | rl_notes_sections)"
    eq "only Fixes" "## Fixes${NL}${NL}- f" "$(printf 'fix: f\n' | rl_notes_sections)"
    eq "all hidden -> no user-facing changes" "## Changes${NL}${NL}- (no user-facing changes)" \
        "$(printf '%s\n' "docs: d" "test: t" | rl_notes_sections)"
    eq "empty -> no user-facing changes" "## Changes${NL}${NL}- (no user-facing changes)" "$(printf '' | rl_notes_sections)"
    echo "PASS=$PASS FAIL=$FAIL" >"$T/sub.counts"
)
. "$T/sub.counts"

new_sandbox notes
merge_feature kilo "docs: kilo" >/dev/null
merge_feature lima "test: lima" >/dev/null
succeeds "beta --dry-run with hidden types only" rel beta --dry-run
eq "  no user-facing changes" "- (no user-facing changes)" "$(notes_sec Changes "$OUT")"
hasnt "  hidden subjects absent" "kilo" "$(printf '%s\n' "$OUT" | sed -n '/notes preview/,/^-----/p')"
hasnt "  conventional hidden types: no warning" "$WARN_UNCONV" "$OUT"
merge_feature mike "perf: mike" >/dev/null
merge_feature november >/dev/null
merge_feature oscar "feat: oscar" >/dev/null
BODY=$(lib rl_notes_body 1.1.0-beta.1 HEAD "Headline")
eq "  body: headline, then groups in order" "Headline|## Features|- oscar|## Performance|- mike|## Other changes|- Merge feat/november: november" \
    "$(printf '%s\n' "$BODY" | grep . | tr '\n' '|' | sed 's/|$//')"
eq "  rl_unconventional lists only the legacy subject" "Merge feat/november: november" "$(lib rl_unconventional 1.1.0-beta.1 HEAD)"
succeeds "beta --dry-run with a legacy subject" rel beta --dry-run
has "  warning printed" "WARNING: these subjects $WARN_UNCONV" "$OUT"
has "  warning names the subject" "           Merge feat/november: november" "$OUT"
hasnt "  warning omits conventional subjects" "           perf: mike" "$OUT"
has "  dry run still completes" "DRY RUN complete" "$OUT"

section "scripts/hooks/commit-msg: convention on main only (opt-in)"
new_sandbox hook
commit() { g commit -q --allow-empty "$@"; }
succeeds "without core.hooksPath nothing is checked" commit -m "anything goes"
g config core.hooksPath scripts/hooks
fails "main: unconventional subject rejected" "must be '<type>: <user-facing summary>'" commit -m "Add a thing"
has "  names the subject" "got:   Add a thing" "$OUT"
has "  shows the merge form" 'git merge --no-ff -m "feat: <summary>"' "$OUT"
fails "main: scope rejected" "must be" commit -m "feat(ui): x"
fails "main: empty-summary rejected" "must be" commit -m "feat:"
for m in "feat: a feature" "fix: a fix" "perf: faster" "docs: d" "test: t" "chore: c" "build: b" "refactor: r" \
    "fixup! Add a thing" "squash! Add a thing" 'Revert "feat: a feature"'; do
    succeeds "main: '$m' accepted" commit -m "$m"
done
printf '\n# a comment line\n\nfeat: from a file\n\nBody text that: is free.\n' >"$T/hook-msg"
succeeds "main: subject = first non-blank, non-comment line" commit --cleanup=strip -F "$T/hook-msg"
eq "  committed subject" "feat: from a file" "$(g log -1 --format=%s)"
g switch -q -c feat/papa
succeeds "feature branch: unconventional subject allowed" commit -m "WIP papa"
g switch -q main
fails "merge to main with the default message rejected" "Merge branch 'feat/papa'" g merge -q --no-ff --no-edit feat/papa
g merge --abort 2>/dev/null || true
fails "merge to main with a legacy message rejected" "must be" g merge -q --no-ff -m "Merge feat/papa: papa" feat/papa
g merge --abort 2>/dev/null || true
succeeds "merge to main with a conventional message accepted" g merge -q --no-ff -m "feat: papa" feat/papa
eq "  merge commit subject" "feat: papa" "$(g log -1 --format=%s)"
g switch -q --detach HEAD
succeeds "detached HEAD: not checked" commit -m "detached anything"
g switch -q main

# =================================================================================
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
