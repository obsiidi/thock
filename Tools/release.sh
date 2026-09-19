#!/bin/zsh
# Builds the bundle and packs it into dist/thock-<version>.dmg with a
# checksum. Upload the DMG to a GitHub Release tagged v<version>; the app's
# update check compares that tag with CFBundleShortVersionString.
set -euo pipefail
cd "$(dirname "$0")/.."

Tools/bundle.sh

APP="dist/thock.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="dist/thock-$VERSION.dmg"
STAGE="dist/dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/thock.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read me first.txt" <<TXT
thock $VERSION

1. Drag thock into Applications.
2. Open it. If macOS says it "was not opened": System Settings >
   Privacy & Security > Open Anyway (one time).
3. Follow the setup window to allow Input Monitoring.

Free and open source: https://github.com/obsiidi/thock
TXT

hdiutil create -volname "thock $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "release: $DMG ($(du -h "$DMG" | cut -f1))"
echo "next: git tag v$VERSION && push, then create the GitHub Release and upload the DMG + .sha256"
