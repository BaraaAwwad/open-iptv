#!/bin/sh
# Quits Open IPTV, installs the latest built Release into /Applications, and reopens it.
set -e
cd "$(dirname "$0")/.."
osascript -e 'quit app "Open IPTV"' 2>/dev/null || true
sleep 1
rm -rf "/Applications/Open IPTV.app"
cp -R "build/Build/Products/Release/Open IPTV.app" /Applications/
open "/Applications/Open IPTV.app"
