#!/bin/bash
# Renders the logo SVGs in Branding/ to PNGs and builds Resources/AppIcon.icns.
# Uses WebKit through scripts/render_svg.swift, so nothing needs installing.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 scripts/make_logo.py

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
B=Branding
I=$B/icon-full.svg

# Every job is: input.svg width height output.png
swift scripts/render_svg.swift \
    $B/social-preview.svg 1280 640 $B/social-preview.png \
    $B/logo-horizontal-dark.svg 1258 240 $B/logo-horizontal-dark.png \
    $B/logo-horizontal-light.svg 1258 240 $B/logo-horizontal-light.png \
    $B/logo-mark.svg 1024 1024 $B/logo-mark.png \
    $B/logo-mark-tiny.svg 16 16 "$ICONSET/icon_16x16.png" \
    $B/logo-mark-small.svg 32 32 "$ICONSET/icon_16x16@2x.png" \
    $B/logo-mark-small.svg 32 32 "$ICONSET/icon_32x32.png" \
    $I 64 64 "$ICONSET/icon_32x32@2x.png" \
    $I 128 128 "$ICONSET/icon_128x128.png" \
    $I 256 256 "$ICONSET/icon_128x128@2x.png" \
    $I 256 256 "$ICONSET/icon_256x256.png" \
    $I 512 512 "$ICONSET/icon_256x256@2x.png" \
    $I 512 512 "$ICONSET/icon_512x512.png" \
    $I 1024 1024 "$ICONSET/icon_512x512@2x.png"
cp "$ICONSET/icon_32x32.png" $B/icon-32.png
cp "$ICONSET/icon_16x16.png" $B/icon-16.png
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns

echo "Rendered PNGs into Branding/ and built Resources/AppIcon.icns"
