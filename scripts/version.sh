#!/bin/bash
# Derives Snappy's version from git — the tag is the single source of truth
# (features/versioning.md). SOURCE this file; it sets:
#
#   SNAPPY_VERSION      nearest v<MAJOR>.<MINOR>.<PATCH> tag, number only (1.1.0)
#                       — the only form CFBundleShortVersionString accepts
#   SNAPPY_DESCRIPTION  the full build string: 1.1.0 exactly on a tag, else
#                       1.1.0-7-gabc1234, plus -dirty with uncommitted changes
#   SNAPPY_BUILD        commit count (monotonic) — CFBundleVersion
#
# With no reachable tag (shallow clone, tarball) the build does not fail: it
# reports 0.0.0 / 0.0.0-<hash> so the oddity is visible instead.
_describe=$(git describe --tags --match 'v[0-9]*.[0-9]*.[0-9]*' --always --dirty 2>/dev/null || true)
if [[ $_describe =~ ^v([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    SNAPPY_VERSION=${BASH_REMATCH[1]}
    SNAPPY_DESCRIPTION=${_describe#v}
else
    SNAPPY_VERSION=0.0.0
    SNAPPY_DESCRIPTION="0.0.0-${_describe:-unknown}"
fi
SNAPPY_BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
unset _describe
