#!/bin/bash
# Builds the release artifact dist/Snappy-<description>.zip: a universal (arm64 +
# x86_64) Snappy.app, ad-hoc signed — the local "Snappy Dev" identity means
# nothing on other Macs. Version comes from the git tag (scripts/version.sh);
# build from a checkout exactly on the tag so the zip reports a clean version.
# Prints the SHA-256 the Homebrew cask needs. Used by release.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/version.sh
SNAPPY_SIGN_IDENTITY=- SNAPPY_UNIVERSAL=1 ./scripts/bundle.sh
./scripts/verify-bundle.sh dist/Snappy.app

# Named by the full description so a beta zip is Snappy-1.5.0-beta.2.zip.
ZIP="dist/Snappy-$SNAPPY_DESCRIPTION.zip"
rm -f "$ZIP"
# ditto keeps the bundle's metadata intact (a plain zip can break the signature).
ditto -c -k --keepParent dist/Snappy.app "$ZIP"
echo "Packaged $ZIP"
shasum -a 256 "$ZIP"
