#!/usr/bin/env bash
# Builds and tests from the command line (ad-hoc signed, runs locally without a developer account).
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project SpaceBridge.xcodeproj -scheme SpaceBridge -configuration Debug -derivedDataPath build/DerivedData build
echo "App: build/DerivedData/Build/Products/Debug/SpaceBridge.app"
if [[ "${1:-}" == "test" ]]; then
  xcodebuild -project SpaceBridge.xcodeproj -scheme SpaceBridge -derivedDataPath build/DerivedData test
fi
