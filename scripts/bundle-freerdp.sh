#!/bin/bash
# Copies Homebrew's sdl-freerdp and every dylib it depends on into an app bundle, and
# rewrites the install names so the copy runs without Homebrew present.
# Works with the bash 3.2 that ships with macOS.
#
# Usage: scripts/bundle-freerdp.sh "/path/to/RDP Manager.app" [signing identity]
# The identity defaults to ad-hoc ("-"). package.sh passes a Developer ID so the copies can
# be notarized: library validation only lets sdl-freerdp load dylibs from its own team.
set -euo pipefail

APP="${1:?usage: $0 /path/to/RDP\ Manager.app [identity]}"
IDENTITY="${2:--}"
SRC="$(brew --prefix)/bin/sdl-freerdp"
DEST="$APP/Contents/Helpers/freerdp"
BIN="$DEST/bin"
LIB="$DEST/lib"

[ -x "$SRC" ] || { echo "sdl-freerdp not found; run: brew install freerdp" >&2; exit 1; }

rm -rf "$DEST"
mkdir -p "$BIN" "$LIB"
cp "$(readlink -f "$SRC")" "$BIN/sdl-freerdp"
chmod u+w "$BIN/sdl-freerdp"

# Breadth-first copy of every non-system dependency. A library is "seen" once it is in $LIB.
queue=("$BIN/sdl-freerdp")
while [ ${#queue[@]} -gt 0 ]; do
  file="${queue[0]}"
  if [ ${#queue[@]} -gt 1 ]; then queue=("${queue[@]:1}"); else queue=(); fi
  deps="$(otool -L "$file" | tail -n +2 | awk '{print $1}')"
  for dep in $deps; do
    case "$dep" in
      /usr/lib/*|/System/*) continue ;;
    esac
    name="$(basename "$dep")"
    if [ ! -e "$LIB/$name" ]; then
      case "$dep" in
        @*) src="$(readlink -f "$(find "$(brew --prefix)/Cellar" -name "$name" | head -1)")"
            [ -n "$src" ] || { echo "cannot locate $dep (needed by $file)" >&2; exit 1; } ;;
        *)  src="$(readlink -f "$dep")" ;;
      esac
      cp "$src" "$LIB/$name"
      chmod u+w "$LIB/$name"
      queue+=("$LIB/$name")
    fi
    if [ "$file" = "$BIN/sdl-freerdp" ]; then
      install_name_tool -change "$dep" "@executable_path/../lib/$name" "$file"
    else
      install_name_tool -change "$dep" "@loader_path/$name" "$file"
    fi
  done
done

for f in "$LIB"/*.dylib; do
  install_name_tool -id "@loader_path/$(basename "$f")" "$f"
done

# Sign everything we touched, innermost first, so macOS will load it. install_name_tool
# invalidated whatever signature the Homebrew copies arrived with.
SIGN_FLAGS=(--force --sign "$IDENTITY")
if [ "$IDENTITY" != "-" ]; then
  # A real identity means this is headed for notarization, which wants the hardened runtime
  # and a timestamp on every executable in the bundle.
  SIGN_FLAGS+=(--options runtime --timestamp)
fi
for f in "$LIB"/*.dylib "$BIN/sdl-freerdp"; do
  codesign "${SIGN_FLAGS[@]}" "$f" >/dev/null 2>&1 \
    || { echo "could not sign $f with identity '$IDENTITY'" >&2; exit 1; }
done

echo "Bundled sdl-freerdp with $(ls "$LIB" | wc -l | tr -d ' ') libraries into $DEST"
