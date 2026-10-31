#!/bin/bash
# Builds rdpm and puts it on PATH. Pass a directory to install somewhere other than
# /usr/local/bin (handy when that needs a password: scripts/install-cli.sh ~/bin).
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="${1:-/usr/local/bin}"
BUILT="$PWD/build/DerivedData/Build/Products/Release/rdpm"

[ -d RDPManager.xcodeproj ] || xcodegen generate
xcodebuild -project RDPManager.xcodeproj -scheme RDPManager -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData build 2>&1 \
  | grep -E "error:|BUILD" || true
[ -x "$BUILT" ] || { echo "build failed: no $BUILT" >&2; exit 1; }

mkdir -p "$DEST" 2>/dev/null || true
if [ -w "$DEST" ]; then
  install -m 755 "$BUILT" "$DEST/rdpm"
else
  echo "$DEST is not writable; installing with sudo"
  sudo install -m 755 "$BUILT" "$DEST/rdpm"
fi

echo "installed $DEST/rdpm"
case ":$PATH:" in
  *":$DEST:"*) "$DEST/rdpm" help | head -3 ;;
  *) echo "note: $DEST is not on your PATH; add it to use rdpm by name" ;;
esac
