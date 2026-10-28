#!/bin/bash
# Assembles build/PCBuds.app from the SwiftPM release build.
#
#   bash Scripts/make_app.sh            # release build (the CI configuration)
#   bash Scripts/make_app.sh --debug    # debug build, for local testing
#
# The bundle is ad-hoc signed. macOS anchors TCC grants (Accessibility, Bluetooth) to the
# signature, so every build of this script keeps the same designated requirement and the
# grants survive a rebuild in place.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION=release
if [[ "${1:-}" == "--debug" ]]; then
    CONFIGURATION=debug
fi

APP_NAME=PCBuds
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
EXECUTABLE=".build/$CONFIGURATION/$APP_NAME"
INFO_PLIST="Resources/Info.plist"
ICON="Resources/AppIcon.icns"
BUNDLE_ID="app.pcbuds.PCBuds"

if [[ ! -f "$INFO_PLIST" ]]; then
    echo "make_app.sh: missing $INFO_PLIST" >&2
    exit 1
fi

echo "==> Building $APP_NAME ($CONFIGURATION)"
swift build -c "$CONFIGURATION"

echo "==> Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"
if [[ -f "$ICON" ]]; then
    cp "$ICON" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

/usr/bin/plutil -lint "$APP_BUNDLE/Contents/Info.plist" >/dev/null

echo "==> Signing (ad-hoc)"
/usr/bin/codesign --force --sign - --timestamp=none --options runtime "$APP_BUNDLE" >/dev/null

echo "==> Verifying"
/usr/bin/codesign --verify --strict "$APP_BUNDLE"
/usr/bin/codesign -dv "$APP_BUNDLE" 2>&1 | sed -n 's/^Identifier=/  identifier: /p'
echo "Built $APP_BUNDLE ($BUNDLE_ID)"
