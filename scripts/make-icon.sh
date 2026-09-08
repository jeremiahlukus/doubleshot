#!/bin/bash
#
# Generates the macOS AppIcon set from a single square source image.
#
#   ./scripts/make-icon.sh ~/Downloads/doubleshot-icon.png
#
# Expects a square PNG, ideally 1024x1024 with transparency. Writes every size
# Xcode wants into DoubleShot/Assets.xcassets/AppIcon.appiconset/.
set -euo pipefail

SRC="${1:-}"
ICONSET="$(cd "$(dirname "$0")/.." && pwd)/DoubleShot/Assets.xcassets/AppIcon.appiconset"

if [[ -z "$SRC" || ! -f "$SRC" ]]; then
    echo "usage: $0 <source.png>" >&2
    exit 1
fi

read -r W H < <(sips -g pixelWidth -g pixelHeight "$SRC" 2>/dev/null | awk '/pixel/{printf "%s ", $2}')
if [[ -z "${W:-}" ]]; then
    echo "Could not read image dimensions from $SRC" >&2
    exit 1
fi
if [[ "$W" != "$H" ]]; then
    echo "warning: source is ${W}x${H}, not square — macOS icons will look stretched" >&2
fi
if (( W < 1024 )); then
    echo "warning: source is only ${W}px wide; 1024 is recommended for the @2x sizes" >&2
fi

# size:filename pairs, matching Contents.json
for spec in \
    16:icon_16x16 32:icon_16x16@2x \
    32:icon_32x32 64:icon_32x32@2x \
    128:icon_128x128 256:icon_128x128@2x \
    256:icon_256x256 512:icon_256x256@2x \
    512:icon_512x512 1024:icon_512x512@2x
do
    px="${spec%%:*}"
    name="${spec##*:}"
    sips -s format png -z "$px" "$px" "$SRC" --out "$ICONSET/$name.png" >/dev/null
    printf "  %-22s %sx%s\n" "$name.png" "$px" "$px"
done

echo
echo "Wrote 10 icons to $ICONSET"
echo "Now run: xcodegen generate && xcodebuild -project DoubleShot.xcodeproj -scheme DoubleShot build"
