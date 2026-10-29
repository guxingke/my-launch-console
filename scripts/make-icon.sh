#!/bin/zsh
# Regenerates Resources/AppIcon.icns from scripts/make-icon.swift.
# Each size is drawn directly rather than scaled down, so small sizes stay sharp.
set -euo pipefail
cd "$(dirname "$0")/.."

ICONSET=build/icon/AppIcon.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET" Resources

for points in 16 32 128 256 512; do
  swift scripts/make-icon.swift "$ICONSET/icon_${points}x${points}.png" $points
  swift scripts/make-icon.swift "$ICONSET/icon_${points}x${points}@2x.png" $((points * 2))
done

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "$PWD/Resources/AppIcon.icns"
