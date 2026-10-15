#!/bin/bash
# M0 smoke check: bundle structure, required Info.plist keys, valid signature.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-dist/Snappy.app}"
PLIST="$APP/Contents/Info.plist"

fail() { echo "FAIL: $1" >&2; exit 1; }

[ -d "$APP" ] || fail "bundle not found: $APP (run scripts/bundle.sh first)"
[ -x "$APP/Contents/MacOS/Snappy" ] || fail "executable missing or not executable"
[ -f "$PLIST" ] || fail "Info.plist missing"

plist_get() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null; }

[ "$(plist_get LSUIElement)" = "true" ] || fail "LSUIElement is not true"
[ -n "$(plist_get NSScreenCaptureUsageDescription)" ] || fail "NSScreenCaptureUsageDescription missing"
[ "$(plist_get LSMinimumSystemVersion)" = "26.0" ] || fail "LSMinimumSystemVersion is not 26.0"
[ "$(plist_get CFBundleIdentifier)" = "com.tefa.snappy" ] || fail "CFBundleIdentifier mismatch"
[ "$(plist_get CFBundleIconFile)" = "AppIcon" ] || fail "CFBundleIconFile is not AppIcon"
[ -f "$APP/Contents/Resources/AppIcon.icns" ] || fail "AppIcon.icns missing"
[ -f "$APP/Contents/Resources/MenuBarIcon@2x.png" ] || fail "MenuBarIcon@2x.png missing"

# Version: derived from git at bundle time, never hardcoded.
source scripts/version.sh
[ "$(plist_get CFBundleShortVersionString)" = "$SNAPPY_VERSION" ] || fail "CFBundleShortVersionString is not $SNAPPY_VERSION"
[ "$(plist_get SnappyBuildDescription)" = "$SNAPPY_DESCRIPTION" ] || fail "SnappyBuildDescription is not $SNAPPY_DESCRIPTION"
[[ "$(plist_get CFBundleVersion)" =~ ^[0-9]+$ ]] || fail "CFBundleVersion is not numeric"

codesign --verify "$APP" || fail "codesign verification failed"

echo "OK: $APP verified"
