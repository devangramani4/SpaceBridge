#!/usr/bin/env bash
# Builds a Developer ID signed, notarized and stapled SpaceBridge.app and SpaceBridge.dmg.
#
# Requirements: Xcode 16+, a "Developer ID Application" certificate in your keychain, and a
# notarytool keychain profile created once with:
#   xcrun notarytool store-credentials SpaceBridgeNotary --apple-id YOU@example.com --team-id TEAMID
#
# Usage:  TEAM_ID=ABCDE12345 ./scripts/release.sh            (sign + notarize + DMG)
#         SKIP_NOTARIZE=1 TEAM_ID=ABCDE12345 ./scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${TEAM_ID:?Set TEAM_ID to your Apple Developer Team ID}"
PROFILE="${NOTARY_PROFILE:-SpaceBridgeNotary}"
BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/SpaceBridge.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/SpaceBridge.app"
DMG="$BUILD_DIR/SpaceBridge.dmg"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Archiving (Release, universal)"
xcodebuild -project SpaceBridge.xcodeproj -scheme SpaceBridge -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp" \
  archive

echo "==> Exporting with Developer ID"
sed "s/YOUR_TEAM_ID/$TEAM_ID/" scripts/ExportOptions.plist > "$BUILD_DIR/ExportOptions.plist"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Authority|TeamIdentifier|Runtime" || true

if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
  echo "==> Notarizing app"
  ditto -c -k --keepParent "$APP" "$BUILD_DIR/SpaceBridge.zip"
  xcrun notarytool submit "$BUILD_DIR/SpaceBridge.zip" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
fi

echo "==> Creating DMG"
./scripts/make_dmg.sh "$APP" "$DMG"
codesign --sign "Developer ID Application" --timestamp "$DMG"

if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
  echo "==> Notarizing DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
  spctl --assess --type execute --verbose "$APP"
fi

echo "Done: $DMG"
