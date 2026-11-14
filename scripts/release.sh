#!/bin/bash
# Builds a universal, Developer ID signed, notarized and stapled "T3 Notch.app", zipped for a
# GitHub Release. Used by .github/workflows/release.yml; also runs locally.
#
#   scripts/release.sh <version>            e.g. scripts/release.sh 0.2.0
#
# Needs, in the keychain: a "Developer ID Application" certificate (or set SIGN_ID).
# Notarization uses an App Store Connect API key from the environment:
#   NOTARY_KEY_PATH (the .p8 file), NOTARY_KEY_ID, NOTARY_ISSUER_ID
# Without them the app is signed but not notarized (fine for a local test, not for release).
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version>}"
cd "$(dirname "$0")/.."
DIST=dist
APP="$DIST/T3 Notch.app"
ZIP="$DIST/T3-Notch-$VERSION.zip"
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk '{print $2}')}"
[ -n "$SIGN_ID" ] || { echo "No Developer ID Application certificate in the keychain." >&2; exit 1; }

echo "Building $VERSION (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64
BIN=".build/apple/Products/Release/T3Notch"

rm -rf "$DIST" && mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/T3Notch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

echo "Signing"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP"

if [ -n "${NOTARY_KEY_PATH:-}" ]; then
  echo "Notarizing"
  ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
  xcrun notarytool submit "$DIST/notarize.zip" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" --wait
  xcrun stapler staple "$APP"
  rm "$DIST/notarize.zip"
  spctl --assess --type execute -vv "$APP"
else
  echo "NOTARY_KEY_PATH not set: skipping notarization (the zip will not open cleanly elsewhere)." >&2
fi

ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
echo "Done: $ZIP"
