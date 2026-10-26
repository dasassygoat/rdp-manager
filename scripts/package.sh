#!/bin/bash
# Builds a Release app, bundles FreeRDP, ad-hoc signs it, and zips it into dist/ for
# copying to another Mac.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(grep -E '^\s+MARKETING_VERSION:' project.yml | awk '{print $2}')"
APP="$PWD/build/DerivedData/Build/Products/Release/RDP Manager.app"
OUT="$PWD/dist/RDP-Manager-$VERSION.zip"

[ -d RDPManager.xcodeproj ] || xcodegen generate
xcodebuild -project RDPManager.xcodeproj -scheme RDPManager -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData build 2>&1 | grep -E "error:|BUILD" || true
[ -d "$APP" ] || { echo "build failed" >&2; exit 1; }

scripts/bundle-freerdp.sh "$APP" 2>&1 | grep -v "invalidate the code signature"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

mkdir -p dist
rm -f "$OUT"
ditto -c -k --keepParent "$APP" "$OUT"
echo "packaged $OUT ($(du -h "$OUT" | cut -f1))"
