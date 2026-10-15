#!/bin/bash
# Regenerates the app icon artifacts from assets/snappy-dynamic-s.png:
# renders both iconset variants + menu bar template PNGs (generate-icons.swift),
# then converts the iconsets to .icns. The two .icns + two menu bar PNGs are
# committed (bundle.sh just copies them); the intermediate iconsets are not.
# Re-run only when the source image changes.
set -euo pipefail
cd "$(dirname "$0")/.."

swift scripts/generate-icons.swift

iconutil -c icns assets/generated/AppIcon.iconset -o assets/generated/AppIcon.icns
iconutil -c icns assets/generated/AppIcon-light.iconset -o assets/generated/AppIcon-light.icns

echo "Wrote assets/generated/{AppIcon.icns,AppIcon-light.icns,MenuBarIcon.png,MenuBarIcon@2x.png}"
