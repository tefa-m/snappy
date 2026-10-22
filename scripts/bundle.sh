#!/bin/bash
# Builds Snappy.app without Xcode: swift build → assemble bundle → sign.
# Signs with the stable "Snappy Dev" identity when it exists (created once via
# scripts/setup-signing.sh) so TCC grants survive rebuilds; falls back to
# ad-hoc, where every rebuild invalidates the Screen Recording grant.
# SNAPPY_SIGN_IDENTITY=- forces ad-hoc (release builds: the local identity
# means nothing on other Macs).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Snappy.app"

if [ "${SNAPPY_UNIVERSAL:-}" = 1 ]; then
    # Command Line Tools have no xcbuild, so `--arch a --arch b` is unavailable:
    # build each slice on its own and merge them.
    for arch in arm64 x86_64; do swift build -c release --arch "$arch"; done
    mkdir -p .build/universal
    lipo -create -output .build/universal/Snappy \
        "$(swift build -c release --arch arm64 --show-bin-path)/Snappy" \
        "$(swift build -c release --arch x86_64 --show-bin-path)/Snappy"
    BIN=.build/universal/Snappy
else
    swift build -c release
    BIN=.build/release/Snappy
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Snappy"

# Icon artifacts are committed; regenerate via scripts/generate-icons.sh only
# when assets/snappy-dynamic-s.png changes.
if [ assets/snappy-dynamic-s.png -nt assets/generated/AppIcon.icns ]; then
    echo "WARNING: assets/snappy-dynamic-s.png is newer than the generated icons —" >&2
    echo "         run scripts/generate-icons.sh to refresh them." >&2
fi
cp assets/generated/AppIcon.icns "$APP/Contents/Resources/"
cp assets/generated/MenuBarIcon.png assets/generated/MenuBarIcon@2x.png "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>Snappy</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.tefa.snappy</string>
	<key>CFBundleName</key>
	<string>Snappy</string>
	<key>CFBundleDisplayName</key>
	<string>Snappy</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.0.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>SnappyBuildDescription</key>
	<string>0.0.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSScreenCaptureUsageDescription</key>
	<string>Snappy needs Screen Recording access to capture screenshots.</string>
</dict>
</plist>
PLIST

# Version comes from the git tag (scripts/version.sh), never hardcoded; the
# placeholders above are overwritten here.
source scripts/version.sh
plist_set() { /usr/libexec/PlistBuddy -c "Set :$1 $2" "$APP/Contents/Info.plist"; }
plist_set CFBundleShortVersionString "$SNAPPY_VERSION"
plist_set CFBundleVersion "$SNAPPY_BUILD"
plist_set SnappyBuildDescription "$SNAPPY_DESCRIPTION"
echo "Version $SNAPPY_DESCRIPTION (build $SNAPPY_BUILD)"

IDENTITY="${SNAPPY_SIGN_IDENTITY:-Snappy Dev}"
if [ "$IDENTITY" != "-" ] && security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$IDENTITY\""; then
    codesign --force -s "$IDENTITY" "$APP"
    echo "Built $APP (signed with '$IDENTITY' — TCC grants survive rebuilds)"
else
    codesign --force -s - "$APP"
    echo "Built $APP (ad-hoc signed — rebuilding invalidates the Screen Recording grant;"
    echo "run scripts/setup-signing.sh once to fix that)"
fi
