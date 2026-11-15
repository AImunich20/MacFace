#!/usr/bin/env bash
# Builds MacFace.app (Release) with Xcode and packages it as build/MacFace-<version>.dmg.
#
#   VERSION=1.3 scripts/build-dmg.sh
#   VERSION=1.3 DEVELOPMENT_TEAM=ABCDE12345 scripts/build-dmg.sh
#
# The build number (CFBundleVersion, which Sparkle compares) is the git commit count, so commit before building.
#
# For public release (no Gatekeeper warning), sign with Developer ID and notarize:
#   xcrun notarytool store-credentials macface-notary --apple-id … --team-id … --password <app-specific>
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=macface-notary scripts/build-dmg.sh
set -euo pipefail

cd "$(dirname "$0")/.."
: "${VERSION:?Set VERSION, e.g. VERSION=1.3}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
DERIVED="build/DerivedData"
APP="$DERIVED/Build/Products/Release/MacFace.app"
STAGE="build/dmg"
DMG="build/MacFace-${VERSION}.dmg"

XCODE_ARGS=(
    -project MacFace.xcodeproj -scheme MacFace -configuration Release
    -derivedDataPath "$DERIVED" -destination "platform=macOS" -allowProvisioningUpdates -allowProvisioningDeviceRegistration
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
)
[[ -n "${DEVELOPMENT_TEAM:-}" ]] && XCODE_ARGS+=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    XCODE_ARGS+=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" OTHER_CODE_SIGN_FLAGS=--timestamp)
fi

rm -rf "$APP"
xcodebuild "${XCODE_ARGS[@]}" build | tail -5
[[ -d "$APP" ]] || { echo "Build failed: $APP not found"; exit 1; }

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read Me.txt" <<'TXT'
MacFace
=======

Install: drag "MacFace" onto the Applications folder, then open it.

First launch: if macOS says the app "can't be opened", open System Settings →
Privacy & Security, scroll down and click "Open Anyway" next to MacFace.
You only need to do this once; updates install from Settings → About.

MacFace needs Camera (to see your face) and Accessibility (to type your
password on the lock screen). Everything runs on your Mac.

ภาษาไทย: ลาก MacFace ไปที่ Applications ถ้าเปิดครั้งแรกไม่ได้ ไปที่
System Settings → Privacy & Security แล้วกด "Open Anyway"
TXT

hdiutil create -volname "MacFace" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
if [[ -n "${SIGN_IDENTITY:-}" ]]; then codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"; fi
rm -rf "$STAGE"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    [[ -n "${SIGN_IDENTITY:-}" ]] || { echo "NOTARY_PROFILE needs SIGN_IDENTITY (Developer ID)"; exit 1; }
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

echo "Created $DMG ($(du -h "$DMG" | cut -f1)), build $BUILD_NUMBER"
