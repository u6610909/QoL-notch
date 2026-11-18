#!/bin/bash
# Builds QoL Notch and wraps it in build/QoL Notch.app (ad-hoc signed, for local use).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/QoLNotch"

APP="build/QoL Notch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/QoLNotch"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# The app icon, drawn from Branding/ by scripts/render_logo.sh.
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# The now-playing helper: a small library the system Perl loads (see Resources/MediaHelper).
mkdir -p "$APP/Contents/Resources"
clang -fobjc-arc -O2 -arch arm64 -arch arm64e -arch x86_64 -dynamiclib -framework Foundation \
    Resources/MediaHelper/qolmedia.m -o "$APP/Contents/Resources/qolmedia.dylib"
cp Resources/MediaHelper/qolmedia.pl "$APP/Contents/Resources/qolmedia.pl"
# Sign with a real identity when there is one, so macOS keeps the app's permissions
# (Desktop, Calendar, Camera, Microphone) from one build to the next. Set QOL_SIGN_ID to choose
# one; otherwise the first Apple Development certificate is used, and ad-hoc signing is the fallback.
SIGN_ID="${QOL_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Apple Development/ { print $2; exit }')}"
SIGN_ID="${SIGN_ID:--}"
[ "$SIGN_ID" = "-" ] && echo "No signing certificate found: signing ad-hoc, so permissions reset on each build."
codesign --force --sign "$SIGN_ID" "$APP/Contents/Resources/qolmedia.dylib"
codesign --force --sign "$SIGN_ID" "$APP"

echo "Built $APP"
