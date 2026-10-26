#!/bin/bash
# Builds the Debug app, bundles FreeRDP into it, then quits any running copy and
# relaunches. Waits for the old process to exit so `open` starts a fresh instance.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-Debug}"
APP="$PWD/build/DerivedData/Build/Products/$CONFIG/RDP Manager.app"

[ -d RDPManager.xcodeproj ] || xcodegen generate
xcodebuild -project RDPManager.xcodeproj -scheme RDPManager -configuration "$CONFIG" \
  -derivedDataPath build/DerivedData build 2>&1 | grep -E "error:|BUILD" || true
[ -d "$APP" ] || { echo "build failed" >&2; exit 1; }

scripts/bundle-freerdp.sh "$APP" 2>&1 | grep -v "invalidate the code signature"
codesign --force --deep --sign - "$APP" 2>/dev/null

osascript -e 'tell application "RDP Manager" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 50); do
  pgrep -xq "RDP Manager" || break
  sleep 0.2
done
pkill -x "RDP Manager" 2>/dev/null || true

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
open "$APP"
echo "launched $APP"
