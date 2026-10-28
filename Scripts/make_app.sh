#!/bin/bash
# Assembles build/PCBuds.app from the SwiftPM release build.
#
#   bash Scripts/make_app.sh              # release build (the CI configuration)
#   bash Scripts/make_app.sh --release    # the same, spelled out for CI
#   bash Scripts/make_app.sh --debug      # debug build, for local testing
#   bash Scripts/make_app.sh --sign "Apple Development: …"   # sign with a certificate
#
# Signing identity, in order of preference:
#   $CODESIGN_IDENTITY                               (what the release script passes)
#   "Apple Development: $PCBuds_SIGNING*"             (a developer certificate in the keychain)
#   ad-hoc (-)                                       (CI, and any machine without a certificate)
#
# macOS anchors TCC grants (Accessibility, Bluetooth) to the signature. Ad-hoc rebuilds keep the
# same requirement by path; a certificate keeps it stable even when the app moves.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION=release
while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug) CONFIGURATION=debug ;;
        --release) CONFIGURATION=release ;;
        --sign) CODESIGN_IDENTITY="${2:?--sign needs an identity}"; shift ;;
        *) echo "make_app.sh: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    CODESIGN_IDENTITY="$("${SECURITY:-/usr/bin/security}" find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development: steve5wutongyu6@163.com/ { print $2; exit }')"
fi
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    CODESIGN_IDENTITY=-
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

if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
    echo "==> Signing (ad-hoc)"
    /usr/bin/codesign --force --sign - --timestamp=none --options runtime "$APP_BUNDLE" >/dev/null
else
    echo "==> Signing ($CODESIGN_IDENTITY)"
    /usr/bin/codesign --force --sign "$CODESIGN_IDENTITY" --timestamp=none --options runtime \
        "$APP_BUNDLE" >/dev/null
fi

echo "==> Verifying"
/usr/bin/codesign --verify --strict "$APP_BUNDLE"
/usr/bin/codesign -dv "$APP_BUNDLE" 2>&1 | sed -n 's/^Identifier=/  identifier: /p'
echo "Built $APP_BUNDLE ($BUNDLE_ID)"
