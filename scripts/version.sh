#!/bin/bash
# Derives Snappy's version from git — the tag is the single source of truth
# (features/versioning.md). SOURCE this file; it sets:
#
#   SNAPPY_VERSION      nearest v<MAJOR>.<MINOR>.<PATCH>[-beta.N] tag, number
#                       only (1.1.0) — the only form CFBundleShortVersionString
#                       accepts
#   SNAPPY_DESCRIPTION  the full build string: 1.1.0 (or 1.2.0-beta.3) exactly
#                       on a tag, else 1.1.0-7-gabc1234, plus -dirty with
#                       uncommitted changes
#   SNAPPY_BUILD        commit count (monotonic) — CFBundleVersion
#
# With tags on HEAD itself, the HIGHEST one wins (versionsort.suffix=- orders
# 1.2.0-beta.3 < 1.2.0), so a lightweight or older tag on the same commit can
# never shadow the release tag. Otherwise `git describe` picks the nearest.
# With no reachable tag (shallow clone, tarball) the build does not fail: it
# reports 0.0.0 / 0.0.0-<hash> so the oddity is visible instead.
_snappy_re='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-beta\.[1-9][0-9]*)?$'
_head_tag=""
for _t in $(git -c versionsort.suffix=- tag --points-at HEAD --sort=-v:refname --list 'v[0-9]*' 2>/dev/null); do
    if [[ $_t =~ $_snappy_re ]]; then _head_tag=$_t; break; fi
done
if [ -n "$_head_tag" ]; then
    _describe=$(git describe --tags --dirty --match "$_head_tag" 2>/dev/null || echo "$_head_tag")
else
    _describe=$(git describe --tags --match 'v[0-9]*.[0-9]*.[0-9]*' --always --dirty 2>/dev/null || true)
fi
if [[ $_describe =~ ^v([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    SNAPPY_VERSION=${BASH_REMATCH[1]}
    SNAPPY_DESCRIPTION=${_describe#v}
else
    SNAPPY_VERSION=0.0.0
    SNAPPY_DESCRIPTION="0.0.0-${_describe:-unknown}"
fi
SNAPPY_BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
unset _describe _snappy_re _head_tag _t
