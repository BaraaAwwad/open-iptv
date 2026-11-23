#!/bin/sh
# Builds an optimized Release and installs it to /Applications/Open IPTV.app.
set -e
cd "$(dirname "$0")/.."
xcodegen generate -q
xcodebuild -project OpenIPTV.xcodeproj -scheme OpenIPTV -configuration Release -derivedDataPath build -destination 'platform=macOS' build | grep -E "error:|BUILD"
rm -rf "/Applications/Open IPTV.app"
cp -R "build/Build/Products/Release/Open IPTV.app" /Applications/
echo "Installed /Applications/Open IPTV.app"
