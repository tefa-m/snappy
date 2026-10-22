#!/bin/bash
# Shared helpers for the release scripts (release.sh, backport.sh, update-tap.sh).
# SOURCE this file; it defines functions only (prefix rl_) and runs nothing.
# Every function works on the git repository of the current directory.
#
# Release model (features/versioning.md): betas vX.Y.0-beta.N and stables vX.Y.0
# are tagged on main; patches vX.Y.Z (Z>0) on release/X.Y. Must run on macOS
# /bin/bash 3.2: no associative arrays, no mapfile, no ${v,,}.

RL_REPO_SLUG=${SNAPPY_RELEASE_REPO:-tefa-m/snappy}
RL_VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-beta\.([1-9][0-9]*))?$'

rl_die() { echo "ERROR: $*" >&2; exit 1; }
rl_info() { echo "==> $*" >&2; }

# rl_parse <version|vversion> — sets RL_X RL_Y RL_Z RL_N (RL_N empty for a
# stable version). Returns 1 for anything that is not X.Y.Z or X.Y.Z-beta.N.
rl_parse() {
    local v=${1#v}
    [[ $v =~ $RL_VERSION_RE ]] || return 1
    RL_X=${BASH_REMATCH[1]} RL_Y=${BASH_REMATCH[2]} RL_Z=${BASH_REMATCH[3]} RL_N=${BASH_REMATCH[5]}
}

rl_valid() { ( rl_parse "$1" ); }

# rl_channel <version> — beta | stable (X.Y.0) | patch (X.Y.Z, Z>0)
rl_channel() {
    rl_parse "$1" || return 1
    if [ -n "$RL_N" ]; then echo beta
    elif [ "$RL_Z" = 0 ]; then echo stable
    else echo patch; fi
}

rl_core() { rl_parse "$1" || return 1; echo "$RL_X.$RL_Y.$RL_Z"; }
rl_line() { rl_parse "$1" || return 1; echo "$RL_X.$RL_Y"; }

# rl_cmp <a> <b> — prints -1, 0 or 1. SemVer for our subset: numeric core,
# then a stable release beats any beta of the same core, then beta.N numeric.
rl_cmp() {
    local a1 a2 a3 an b1 b2 b3 bn i
    rl_parse "$1" || { echo "rl_cmp: bad version '$1'" >&2; return 2; }
    a1=$RL_X a2=$RL_Y a3=$RL_Z an=$RL_N
    rl_parse "$2" || { echo "rl_cmp: bad version '$2'" >&2; return 2; }
    b1=$RL_X b2=$RL_Y b3=$RL_Z bn=$RL_N
    for i in 1 2 3; do
        eval "local x=\$a$i y=\$b$i"
        if [ "$x" -lt "$y" ]; then echo -1; return 0; fi
        if [ "$x" -gt "$y" ]; then echo 1; return 0; fi
    done
    if [ "$an" = "$bn" ]; then echo 0
    elif [ -z "$an" ]; then echo 1
    elif [ -z "$bn" ]; then echo -1
    elif [ "$an" -lt "$bn" ]; then echo -1
    else echo 1; fi
}

rl_gt() { [ "$(rl_cmp "$1" "$2")" = 1 ]; }

# rl_tags — all release tags, highest first. versionsort.suffix=- puts
# v1.5.0-beta.N before v1.5.0 (plain `sort -V` gets that wrong on macOS) and
# compares beta.2 < beta.11 numerically. Anything not X.Y.Z[-beta.N] is ignored.
rl_tags() {
    local t
    git -c versionsort.suffix=- tag --sort=-v:refname --list 'v[0-9]*' | while read -r t; do
        rl_valid "$t" && echo "$t"
    done
    return 0
}

# rl_latest_stable — highest stable tag (any line), empty if none.
rl_latest_stable() {
    local t
    for t in $(rl_tags); do
        case $t in *-*) ;; *) echo "$t"; return 0 ;; esac
    done
}

# rl_betas_of <X.Y.Z> — beta tags of that core, highest first.
rl_betas_of() {
    local t
    for t in $(rl_tags); do
        case $t in "v$1-beta."*) echo "$t" ;; esac
    done
}

rl_tag_exists() { git rev-parse -q --verify "refs/tags/$1" >/dev/null; }
rl_commit_of() { git rev-parse "$1^{commit}"; }

# rl_open_train — core X.Y.Z of the open beta train: the highest beta whose
# core has no stable tag yet and is above the latest stable. Empty if none.
rl_open_train() {
    local t core latest
    t=$(rl_tags | grep -- '-beta\.' | head -n 1 || true)
    [ -n "$t" ] || return 0
    core=$(rl_core "$t")
    rl_tag_exists "v$core" && return 0
    latest=$(rl_latest_stable)
    if [ -n "$latest" ] && ! rl_gt "$core" "$latest"; then return 0; fi
    echo "$core"
}

# rl_next_beta_n <X.Y.Z> — the N the next beta of that core gets.
rl_next_beta_n() {
    local t
    t=$(rl_betas_of "$1" | head -n 1)
    if [ -z "$t" ]; then echo 1; else rl_parse "$t"; echo $((RL_N + 1)); fi
}

# rl_bump <X.Y.Z> <major|minor|patch> — next core version.
rl_bump() {
    rl_parse "$1" || return 1
    case $2 in
        major) echo "$((RL_X + 1)).0.0" ;;
        minor) echo "$RL_X.$((RL_Y + 1)).0" ;;
        patch) echo "$RL_X.$RL_Y.$((RL_Z + 1))" ;;
        *) return 1 ;;
    esac
}

# rl_line_tags <X.Y> — stable tags vX.Y.* (incl. patches), highest first.
rl_line_tags() {
    local t
    for t in $(rl_tags); do
        case $t in "v$1."*-*) ;; "v$1."*) echo "$t" ;; esac
    done
}

# rl_prev_stable_reachable <commit> [exclude-tag] — the latest stable tag
# reachable from <commit> (patch tags on release branches are not reachable
# from main). Empty if none.
rl_prev_stable_reachable() {
    git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' --exclude '*-*' \
        ${2:+--exclude "$2"} "$1" 2>/dev/null || true
}

# rl_prev_tag <version> <commit> — the tag the notes and compare link start at:
#   beta.N   -> beta.(N-1) of the train; beta.1 -> latest stable reachable
#   X.Y.0    -> latest stable reachable (never a beta)
#   X.Y.Z    -> the highest vX.Y.* below it
rl_prev_tag() {
    local v=$1 commit=$2 t
    case $(rl_channel "$v") in
        beta)
            for t in $(rl_betas_of "$(rl_core "$v")"); do
                rl_gt "$v" "$t" && { echo "$t"; return 0; }
            done
            rl_prev_stable_reachable "$commit" "v$v" ;;
        stable)
            rl_prev_stable_reachable "$commit" "v$v" ;;
        patch)
            for t in $(rl_line_tags "$(rl_line "$v")"); do
                rl_gt "$v" "$t" && { echo "$t"; return 0; }
            done ;;
    esac
    return 0
}

# rl_pick_shas <commit> — the 40-hex shas of all "(cherry picked from commit …)"
# trailers in that commit's message.
rl_pick_shas() {
    git log -1 --format=%B "$1" | grep -oE '\(cherry picked from commit [0-9a-f]{40}\)' |
        grep -oE '[0-9a-f]{40}' || true
}

# rl_provenance_gate <main-ref> — for every origin/release/* branch, every
# non-merge commit since vX.Y.0 must carry a cherry-pick trailer whose sha is
# an ancestor of <main-ref> (default origin/main). Prints offenders, returns 1.
rl_provenance_gate() {
    local main=${1:-origin/main} br line base c sha ok bad=0
    for br in $(git for-each-ref --format='%(refname:strip=3)' 'refs/remotes/origin/release/'); do
        line=${br#release/}
        if ! [[ $line =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
            echo "  origin/$br: not a release/X.Y branch name" >&2; bad=1; continue
        fi
        base="v$line.0"
        if ! rl_tag_exists "$base"; then
            echo "  origin/$br: base tag $base does not exist" >&2; bad=1; continue
        fi
        for c in $(git rev-list --no-merges "$base..origin/$br"); do
            ok=0
            for sha in $(rl_pick_shas "$c"); do
                if git merge-base --is-ancestor "$sha" "$main" 2>/dev/null; then ok=1; break; fi
            done
            if [ "$ok" = 0 ]; then
                echo "  origin/$br: $(git log -1 --format='%h %s' "$c")" >&2; bad=1
            fi
        done
    done
    if [ "$bad" = 1 ]; then
        echo "Provenance gate FAILED: the commits above are not cherry-picks (-x) of commits on $main." >&2
        echo "Land every fix on main first, then back-port it with scripts/backport.sh (forward-port a direct hotfix)." >&2
        return 1
    fi
}

rl_release_url() { echo "https://github.com/$RL_REPO_SLUG/releases/tag/$1"; }
rl_compare_url() { echo "https://github.com/$RL_REPO_SLUG/compare/$1...$2"; }

# rl_shipped_picks <version> <prev-stable-tag> — "sha X.Y.Z" lines: every main
# commit already shipped as a cherry-pick in a patch release of prev's line
# (below <version>), each mapped to the first patch that contained it.
rl_shipped_picks() {
    local v=$1 prev=$2 line t c sha seen=""
    [ -n "$prev" ] || return 0
    line=$(rl_line "$prev")
    for t in $(rl_line_tags "$line" | awk '{ a[NR] = $0 } END { for (i = NR; i > 0; i--) print a[i] }'); do
        rl_gt "${t#v}" "${prev#v}" || continue
        rl_gt "$v" "$t" || continue
        for c in $(git rev-list --no-merges "$prev..$t"); do
            for sha in $(rl_pick_shas "$c"); do
                case $seen in *"$sha"*) continue ;; esac
                seen="$seen $sha"
                echo "$sha ${t#v}"
            done
        done
    done
    return 0
}

# rl_notes_body <version> <commit> [headline] — release notes without the
# footer (the footer needs the zip's SHA-256). Local from git, no PR lookups.
rl_notes_body() {
    local v=$1 commit=$2 headline=${3:-} prev channel list shipped also="" sha subj ver t
    channel=$(rl_channel "$v")
    prev=$(rl_prev_tag "$v" "$commit")
    [ -z "$headline" ] || printf '%s\n\n' "$headline"
    case $channel in
        beta)
            list=$(git log --first-parent --format='- %s' ${prev:+"$prev.."}"$commit") ;;
        patch)
            list=$(git log --no-merges --format='- %s' ${prev:+"$prev.."}"$commit") ;;
        stable)
            shipped=$(rl_shipped_picks "$v" "$prev")
            list=""
            while read -r sha subj; do
                [ -n "$sha" ] || continue
                ver=$(printf '%s\n' "$shipped" | awk -v s="$sha" '$1 == s { print $2; exit }')
                if [ -n "$ver" ]; then also="$also- $subj (also in $ver)"$'\n'
                else list="$list- $subj"$'\n'; fi
            done <<EOF
$(git log --first-parent --format='%H %s' ${prev:+"$prev.."}"$commit")
EOF
            list=${list%$'\n'} also=${also%$'\n'} ;;
    esac
    printf '## Changes\n\n%s\n' "${list:-- (no changes)}"
    if [ -n "$also" ]; then
        printf '\n## Already shipped in patch releases\n\n%s\n' "$also"
    fi
    if [ "$channel" = stable ]; then
        local betas
        betas=$(rl_betas_of "$(rl_core "$v")" | awk '{ a[NR] = $0 } END { for (i = NR; i > 0; i--) print a[i] }')
        if [ -n "$betas" ]; then
            printf '\n## Pre-releases\n\n'
            for t in $betas; do printf -- '- [%s](%s)\n' "$t" "$(rl_release_url "$t")"; done
        fi
    fi
}

# rl_notes_footer <version> <prev-tag> <sha256>
rl_notes_footer() {
    local v=$1 prev=$2 sum=$3 token=snappy
    [ "$(rl_channel "$v")" = beta ] && token=snappy@beta
    printf '\n---\n\n'
    [ "$token" = snappy@beta ] && printf '**Pre-release, may be unstable.**\n\n'
    [ -z "$prev" ] || printf '**Full changelog:** %s\n\n' "$(rl_compare_url "$prev" "v$v")"
    printf 'Install: `brew install --cask tefa-m/snappy/%s`\n\n' "$token"
    printf 'SHA-256 (`Snappy-%s.zip`): `%s`\n' "$v" "$sum"
}

# rl_run_tests <dir> — the release test gate, run inside <dir>.
rl_run_tests() {
    ( cd "$1" && bash -c "${SNAPPY_RELEASE_TEST_CMD:-./scripts/test.sh}" )
}
