#!/bin/bash
# Runs the test suite. With Command Line Tools only (no Xcode), Testing.framework
# and its interop dylib live outside the default search paths, so they must be
# passed explicitly; with full Xcode installed this reduces to plain `swift test`.
set -euo pipefail
cd "$(dirname "$0")/.."

DEV_DIR="$(xcode-select -p)"
FWK="$DEV_DIR/Library/Developer/Frameworks"
LIB="$DEV_DIR/Library/Developer/usr/lib"

ARGS=()
if [ -d "$FWK/Testing.framework" ] && [ -f "$LIB/lib_TestingInterop.dylib" ]; then
    ARGS+=(
        -Xswiftc -F"$FWK"
        -Xlinker -F"$FWK"
        -Xlinker -rpath -Xlinker "$FWK"
        -Xlinker -rpath -Xlinker "$LIB"
    )
fi

swift test ${ARGS[@]+"${ARGS[@]}"} "$@"
