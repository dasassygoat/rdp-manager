#!/bin/bash
# Regenerates RDPManager/Assets.xcassets/AppIcon.appiconset from scripts/make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
SET=RDPManager/Assets.xcassets/AppIcon.appiconset
mkdir -p "$SET"
swift scripts/make-icon.swift "$SET/icon_512x512@2x.png"
for spec in "16:1" "16:2" "32:1" "32:2" "128:1" "128:2" "256:1" "256:2" "512:1"; do
  pt="${spec%%:*}"; scale="${spec##*:}"; px=$((pt * scale))
  name="icon_${pt}x${pt}.png"; [ "$scale" = "2" ] && name="icon_${pt}x${pt}@2x.png"
  sips -z "$px" "$px" "$SET/icon_512x512@2x.png" --out "$SET/$name" >/dev/null
done
cat > "$SET/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png",      "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png",      "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png",    "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png",    "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png",    "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
cat > RDPManager/Assets.xcassets/Contents.json <<'JSON'
{ "info" : { "author" : "xcode", "version" : 1 } }
JSON
echo "icon set written to $SET"
