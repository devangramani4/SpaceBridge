#!/usr/bin/env bash
# Creates a compressed drag-to-install DMG from a built .app using only built-in tools.
# Usage: ./scripts/make_dmg.sh path/to/SpaceBridge.app path/to/SpaceBridge.dmg
set -euo pipefail
APP="${1:?path to .app}"
DMG="${2:-SpaceBridge.dmg}"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "SpaceBridge" -srcfolder "$STAGING" -ov -format UDZO -fs HFS+ "$DMG"
echo "Created $DMG"
