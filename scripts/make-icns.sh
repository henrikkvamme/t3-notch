#!/bin/bash
# Renders the icon and builds Resources/AppIcon.icns and docs/logo.png from it.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
swift scripts/icon.swift "$WORK" icon >/dev/null
SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$WORK/icon-1024.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$WORK/icon-1024.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
sips -z 256 256 "$WORK/icon-1024.png" --out docs/logo.png >/dev/null
rm -rf "$WORK"
echo "Wrote Resources/AppIcon.icns and docs/logo.png"
