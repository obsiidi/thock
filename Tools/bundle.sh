#!/bin/zsh
# Builds dist/thock.app (universal) from the SPM release binaries and signs it.
#
#   Tools/bundle.sh            sign with identity "thock-dev" (self-signed,
#                              Tools/make-cert.sh), ad-hoc if missing
#   THOCK_IDENTITY=name ...    another identity; a "Developer ID Application"
#                              identity enables hardened runtime + timestamp
#   THOCK_NOTARIZE=1 ...       after signing with a Developer ID: submit to
#                              notarytool (keychain profile "thock-notary",
#                              set up once with `xcrun notarytool store-credentials`)
#                              and staple the ticket
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${THOCK_IDENTITY:-thock-dev}"
BUNDLE_ID="com.obsidi.thock"
APP="dist/thock.app"

# Universal binary: one build per architecture, joined with lipo.
swift build -c release --triple arm64-apple-macosx 2>&1 | tail -1
swift build -c release --triple x86_64-apple-macosx 2>&1 | tail -1

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Samples"
lipo -create .build/arm64-apple-macosx/release/thock .build/x86_64-apple-macosx/release/thock \
     -output "$APP/Contents/MacOS/thock"
lipo -info "$APP/Contents/MacOS/thock"
cp Tools/Info.plist "$APP/Contents/Info.plist"
cp Tools/thock.icns "$APP/Contents/Resources/thock.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp -R packs "$APP/Contents/Resources/packs"
rm -f "$APP/Contents/Resources/packs/.gitkeep"
cp Samples/click.wav "$APP/Contents/Resources/Samples/click.wav"
mkdir -p "$APP/Contents/Resources/fonts"
cp site/fonts/*.woff2 site/fonts/OFL-*.txt "$APP/Contents/Resources/fonts/"

plutil -lint "$APP/Contents/Info.plist"

if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
    if [[ "$IDENTITY" == Developer\ ID* ]]; then
        codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" --options runtime --timestamp "$APP"
        echo "signed with Developer ID: $IDENTITY (hardened runtime)"
        if [[ "${THOCK_NOTARIZE:-0}" == "1" ]]; then
            ditto -c -k --keepParent "$APP" dist/notarize.zip
            xcrun notarytool submit dist/notarize.zip --keychain-profile thock-notary --wait
            xcrun stapler staple "$APP"
            rm -f dist/notarize.zip
            echo "notarized and stapled"
        fi
    else
        codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$APP"
        echo "signed with identity: $IDENTITY"
    fi
else
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
    echo "WARNING: no code-signing identity \"$IDENTITY\" in the keychain — signed ad-hoc."
    echo "         Input Monitoring must be granted again after every rebuild."
    echo "         Create it: Keychain Access > Certificate Assistant > Create a Certificate,"
    echo "         name \"$IDENTITY\", type \"Code Signing\"."
fi

codesign --verify --deep --strict "$APP"
codesign -dv "$APP" 2>&1 | grep -E "^(Identifier|Authority|Signature|TeamIdentifier)" || true
echo "bundle: $APP ($(du -sh "$APP" | cut -f1))"
