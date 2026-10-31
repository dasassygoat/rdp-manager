#!/bin/bash
# Puts rdpm on PATH by linking to the copy inside RDP Manager.app, so replacing the app
# updates the command too. Builds the app first only if no copy can be found.
#
# Usage: scripts/install-cli.sh [destination directory]   (default /usr/local/bin)
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="${1:-/usr/local/bin}"
BUILT_APP="$PWD/build/DerivedData/Build/Products/Release/RDP Manager.app"

find_rdpm() {
  for app in "/Applications/RDP Manager.app" "$HOME/Applications/RDP Manager.app" \
             "$BUILT_APP" "$PWD/build/DerivedData/Build/Products/Debug/RDP Manager.app"; do
    if [ -x "$app/Contents/Helpers/rdpm" ]; then
      echo "$app/Contents/Helpers/rdpm"
      return 0
    fi
  done
  return 1
}

if ! RDPM="$(find_rdpm)"; then
  echo "no installed RDP Manager.app found; building one"
  [ -d RDPManager.xcodeproj ] || xcodegen generate
  xcodebuild -project RDPManager.xcodeproj -scheme RDPManager -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData build 2>&1 \
    | grep -E "error:|BUILD" || true
  RDPM="$(find_rdpm)" || { echo "build produced no rdpm" >&2; exit 1; }
fi

mkdir -p "$DEST" 2>/dev/null || true
if [ -w "$DEST" ]; then
  ln -sfn "$RDPM" "$DEST/rdpm"
else
  echo "$DEST is not writable; linking with sudo"
  sudo ln -sfn "$RDPM" "$DEST/rdpm"
fi

echo "linked $DEST/rdpm -> $RDPM"
case ":$PATH:" in
  *":$DEST:"*) "$DEST/rdpm" help | head -2 ;;
  *) echo "note: $DEST is not on your PATH; add it to use rdpm by name" ;;
esac
