#!/bin/bash
# Builds the release DMG: signed PCBuds.app + Applications link inside a styled disk image.
#
#   bash Scripts/make_dmg.sh                 # auto: developer certificate if present, else ad-hoc
#   bash Scripts/make_dmg.sh --ad-hoc        # CI machines without a keychain
#
# Output: release/PCBuds-<version>.dmg
set -euo pipefail

cd "$(dirname "$0")/.."

SIGN_ARGS_SET=0
SIGN_ARGS=()
if [[ "${1:-}" == "--ad-hoc" ]]; then
    SIGN_ARGS_SET=1
    SIGN_ARGS=(--sign -)
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
VOLUME_NAME="PCBuds"
DMG_STAGE="build/dmg"
DMG_OUT="release/PCBuds-$VERSION.dmg"

echo "==> Building PCBuds.app (release)"
rm -rf "$DMG_STAGE"
bash Scripts/make_app.sh "${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"}"

echo "==> Staging disk image"
mkdir -p "$DMG_STAGE"
cp -R "build/PCBuds.app" "$DMG_STAGE/$VOLUME_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"

mkdir -p release
rm -f "$DMG_OUT"

echo "==> Building $DMG_OUT"
if hdiutil create -quiet -volname "$VOLUME_NAME" -srcfolder "$DMG_STAGE" \
        -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG_OUT" >/dev/null; then
    echo "==> Signing disk image"
    if [[ "$SIGN_ARGS_SET" -eq 1 ]]; then
        /usr/bin/codesign --force --sign - --timestamp=none "$DMG_OUT" >/dev/null
    fi
    echo "Built $DMG_OUT"
else
    # HFS+ keeps the Finder layout intact on every macOS version; APFS is the fallback
    # for hosts whose hdiutil no longer ships the HFS+ reader.
    echo "==> HFS+ unavailable, retrying with APFS"
    hdiutil create -quiet -volname "$VOLUME_NAME" -srcfolder "$DMG_STAGE" \
        -fs APFS -format UDZO -imagekey zlib-level=9 "$DMG_OUT" >/dev/null
    echo "Built $DMG_OUT"
fi

rm -rf "$DMG_STAGE"
hdiutil verify -quiet "$DMG_OUT" >/dev/null && echo "Verified $DMG_OUT"
