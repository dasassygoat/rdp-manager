#!/bin/bash
# Builds a Release app, bundles FreeRDP, signs it with the Developer ID, notarizes it and
# staples the ticket, then zips it into dist/ for copying to another Mac.
#
# Notarization needs a stored credential profile, created once with:
#   xcrun notarytool store-credentials notarytool \
#     --apple-id <your Apple ID> --team-id <your team id>
# Without one the app is still signed; it just carries no ticket, so the first launch on
# another Mac shows the Privacy & Security prompt.
#
# Environment:
#   SIGN_IDENTITY   override the signing identity (default: the Developer ID found)
#   NOTARY_PROFILE  notarytool keychain profile name (default: notarytool)
#   SKIP_NOTARIZE   set to 1 to sign without notarizing
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(grep -E '^\s+MARKETING_VERSION:' project.yml | awk '{print $2}')"
APP="$PWD/build/DerivedData/Build/Products/Release/RDP Manager.app"
OUT="$PWD/dist/RDP-Manager-$VERSION.zip"
ENTITLEMENTS="$PWD/RDPManager/RDPManager.entitlements"
NOTARY_PROFILE="${NOTARY_PROFILE:-notarytool}"

# Pick the Developer ID unless one was given. Falling back to ad-hoc keeps the script
# usable on a Mac without the certificate, with the consequence spelled out.
if [ -z "${SIGN_IDENTITY:-}" ]; then
  # `|| true`: with pipefail a Mac holding no identities at all would otherwise abort here.
  SIGN_IDENTITY="$({ security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1; } || true)"
fi
if [ -z "$SIGN_IDENTITY" ]; then
  echo "warning: no Developer ID Application certificate found; signing ad-hoc." >&2
  echo "         the result cannot be notarized and will warn on first launch." >&2
  SIGN_IDENTITY="-"
fi
echo "signing as: $SIGN_IDENTITY"

[ -d RDPManager.xcodeproj ] || xcodegen generate
xcodebuild -project RDPManager.xcodeproj -scheme RDPManager -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData build 2>&1 \
  | grep -E "error:|BUILD" || true
[ -d "$APP" ] || { echo "build failed" >&2; exit 1; }

# Adding the helpers invalidates the signature xcodebuild applied, so the bundle is signed
# again afterwards. Inner code first, outer bundle last: --deep is not a substitute.
scripts/bundle-freerdp.sh "$APP" "$SIGN_IDENTITY" 2>&1 | grep -v "invalidate the code signature"

SIGN_FLAGS=(--force --sign "$SIGN_IDENTITY")
# An `&&` list would end the script under `set -e` whenever the test is false.
if [ "$SIGN_IDENTITY" != "-" ]; then
  SIGN_FLAGS+=(--options runtime --timestamp)
fi
codesign "${SIGN_FLAGS[@]}" --entitlements "$ENTITLEMENTS" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
if [ "$SIGN_IDENTITY" != "-" ]; then
  # Captured rather than piped into `grep -q`: that quits on the first match, which
  # SIGPIPEs codesign, and pipefail then fails the pipeline even though it matched.
  for binary in "$APP" "$APP/Contents/Helpers/freerdp/bin/sdl-freerdp"; do
    DESCRIPTION="$(codesign -d --verbose=4 "$binary" 2>&1 || true)"
    case "$DESCRIPTION" in
      *"(runtime)"*) ;;
      *) echo "hardened runtime missing on $binary; notarization would be rejected" >&2
         exit 1 ;;
    esac
    case "$DESCRIPTION" in
      *"Timestamp="*) ;;
      *) echo "no secure timestamp on $binary; notarization would be rejected" >&2
         exit 1 ;;
    esac
  done
  echo "signed with hardened runtime and a secure timestamp"
fi

mkdir -p dist
rm -f "$OUT"
ditto -c -k --keepParent "$APP" "$OUT"

# Notarize the zip, then staple the ticket to the .app and zip it again, because stapling
# changes the bundle. A stapled app validates without a network round trip on first launch.
if [ "$SIGN_IDENTITY" = "-" ] || [ "${SKIP_NOTARIZE:-}" = "1" ]; then
  echo "skipping notarization"
elif ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  cat >&2 <<EOF
warning: no notarytool profile "$NOTARY_PROFILE"; the app is signed but not notarized.
         create one once with:
           xcrun notarytool store-credentials $NOTARY_PROFILE \\
             --apple-id <your Apple ID> --team-id <your team id>
EOF
else
  echo "submitting for notarization (this usually takes a few minutes)…"
  xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  rm -f "$OUT"
  ditto -c -k --keepParent "$APP" "$OUT"
  spctl -a -vvv -t install "$APP" || true
fi

echo "packaged $OUT ($(du -h "$OUT" | cut -f1))"
