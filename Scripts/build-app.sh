#!/bin/bash
# Builds VirtualBar and assembles it into a proper .app bundle so macOS
# grants Accessibility permission to "VirtualBar" itself, not to whatever
# shell happened to launch the raw executable.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"

cd "$ROOT_DIR"
swift build -c "$CONFIG"

BIN_PATH="$ROOT_DIR/.build/$CONFIG/VirtualBar"
APP_DIR="$ROOT_DIR/.build/$CONFIG/VirtualBar.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/VirtualBar"
cp "$ROOT_DIR/Sources/VirtualBar/Info.plist" "$APP_DIR/Contents/Info.plist"

# Info.plist points CFBundleIconFile at "AppIcon"; without this the key
# resolves to nothing and the bundle silently falls back to the generic
# application icon.
if [ -f "$ROOT_DIR/Resources/AppIcon.icns" ]; then
    mkdir -p "$APP_DIR/Contents/Resources"
    cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

codesign --force --deep --sign - "$APP_DIR"

# Ad-hoc signing gives the bundle a fresh CDHash on every build, so the
# existing TCC grants stop matching it. Left alone, System Settings keeps
# showing the toggles as ON while the app reads the permissions as denied —
# and in that state the toggles can't be usefully changed by hand. Clearing
# the entries here means the next launch prompts cleanly instead.
#
# The grants are keyed by bundle id, not by path, so this also revokes them
# from any other VirtualBar build that is running. Packaging a release is not
# about to be launched and granted here, so KEEP_TCC=1 skips the reset there.
BUNDLE_ID="com.virtualbar.app"
if [ "${KEEP_TCC:-0}" = "1" ]; then
    echo "Kept TCC grants for $BUNDLE_ID (KEEP_TCC=1)"
else
    for service in Accessibility ScreenCapture; do
        tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1 || true
    done
    echo "Cleared TCC grants for $BUNDLE_ID (rebuild invalidates them)"
fi

echo "Built $APP_DIR"
