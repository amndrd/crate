#!/bin/bash
# Builds Resources/AppIcon.icns and docs/icon.png from Resources/AppIcon.png (1024 × 1024).
# The vector source of the icon is Resources/AppIcon.svg.
set -euo pipefail
cd "$(dirname "$0")/.."

iconset="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o Resources/AppIcon.icns
sips -z 512 512 Resources/AppIcon.png --out docs/icon.png >/dev/null
echo "Resources/AppIcon.icns, docs/icon.png"
