#!/bin/sh
# Builds a self-contained, Developer ID–signed and notarized Open IPTV for download.
#   scripts/release.sh 1.0.0
# Output in dist/: Open-IPTV-<version>.dmg, Open-IPTV-<version>.zip and SHA256SUMS.txt
set -eu
VERSION="${1:?usage: scripts/release.sh <version>}"
cd "$(dirname "$0")/.."
ROOT="$PWD"
ARCHIVE="$ROOT/build/release/OpenIPTV.xcarchive"
APP="$ARCHIVE/Products/Applications/Open IPTV.app"
OUT="$ROOT/build/release/export"
DIST="$ROOT/dist"
rm -rf build/release "$DIST"; mkdir -p build/release "$DIST"

echo "› Archiving $VERSION"
xcodegen generate -q
xcodebuild archive -project OpenIPTV.xcodeproj -scheme OpenIPTV -configuration Release \
  -archivePath "$ARCHIVE" -destination 'generic/platform=macOS' \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M)" ARCHS=arm64 \
  CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates -quiet

echo "› Bundling libmpv and its libraries into the app"
dylibbundler -od -b -cd -x "$APP/Contents/MacOS/Open IPTV" -d "$APP/Contents/Frameworks/" \
  -p "@executable_path/../Frameworks/" -s /opt/homebrew/lib >/dev/null
# dylibbundler adds rpaths that may already exist; macOS refuses duplicates, so keep one of each.
dedupe_rpaths() {
  for rp in $(otool -l "$1" | awk '/LC_RPATH/{getline; getline; print $2}' | sort | uniq -d); do
    while [ "$(otool -l "$1" | awk '/LC_RPATH/{getline; getline; print $2}' | grep -cx "$rp")" -gt 1 ]; do
      install_name_tool -delete_rpath "$rp" "$1" 2>/dev/null
    done
  done
}
dedupe_rpaths "$APP/Contents/MacOS/Open IPTV"
for f in "$APP"/Contents/Frameworks/*.dylib; do dedupe_rpaths "$f"; done

if security find-identity -v -p codesigning | grep -q "Developer ID Application" && [ -n "${NOTARY_KEY_PATH:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ]; then
  IDENTITY="$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')"
  echo "› Signing with $IDENTITY (hardened runtime) and notarizing"
  find "$APP/Contents/Frameworks" -name "*.dylib" -exec codesign --force --timestamp --options runtime -s "$IDENTITY" {} \;
  codesign --force --timestamp --options runtime --entitlements OpenIPTV/OpenIPTV.entitlements -s "$IDENTITY" "$APP"
  ditto -c -k --keepParent "$APP" build/release/notarize.zip
  xcrun notarytool submit build/release/notarize.zip --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  xcrun stapler staple "$APP"
  NOTARIZED_NOTE="Signed with Developer ID and notarized by Apple."
else
  echo "› No Developer ID + notary key here: ad-hoc signing (first launch needs right-click → Open)"
  find "$APP/Contents/Frameworks" -name "*.dylib" -exec codesign --force -s - {} \;
  codesign --force -s - "$APP"   # no hardened runtime: it only applies to notarized Developer ID builds
  NOTARIZED_NOTE="Ad-hoc signed (not notarized)."
fi
codesign --verify --deep --strict "$APP" && echo "› Signature verified"
mkdir -p "$OUT/notarized" && ditto "$APP" "$OUT/notarized/Open IPTV.app"

echo "› Packaging"
ditto -c -k --keepParent "$OUT/notarized/Open IPTV.app" "$DIST/Open-IPTV-$VERSION.zip"
create-dmg --volname "Open IPTV $VERSION" --window-size 540 340 --icon-size 110 \
  --icon "Open IPTV.app" 140 160 --app-drop-link 400 160 --hide-extension "Open IPTV.app" \
  "$DIST/Open-IPTV-$VERSION.dmg" "$OUT/notarized/" >/dev/null
(cd "$DIST" && shasum -a 256 *.dmg *.zip > SHA256SUMS.txt && cat SHA256SUMS.txt)
echo "$NOTARIZED_NOTE" > "$DIST/SIGNING.txt"
echo "› Done: $DIST ($NOTARIZED_NOTE)"
