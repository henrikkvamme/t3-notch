#!/bin/bash
# Builds an Apple silicon (arm64), Developer ID signed, notarized and stapled "T3 Notch.app", and
# packs it two ways for a GitHub Release:
#   T3-Notch-<version>.dmg  the download for people: drag the app into Applications.
#   T3-Notch.dmg            the same DMG under a fixed name, for the releases/latest/download link.
#   T3-Notch-<version>.zip  what installed copies download to update themselves (Updater.swift).
# Used by .github/workflows/release.yml; also runs locally.
#
#   scripts/release.sh <version>            e.g. scripts/release.sh 0.2.0
#
# Signing uses the first "Developer ID Application" certificate in the keychain, or SIGN_ID.
# Notarization uses an App Store Connect API key from the environment:
#   NOTARY_KEY_PATH (the .p8 file), NOTARY_KEY_ID, NOTARY_ISSUER_ID
# Without a certificate (only outside CI) the app is signed ad-hoc and the DMG is not signed;
# without the key nothing is notarized. Both are fine for a local test, not for a release.
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version>}"
cd "$(dirname "$0")/.."
DIST=dist
APP="$DIST/T3 Notch.app"
ZIP="$DIST/T3-Notch-$VERSION.zip"
DMG="$DIST/T3-Notch-$VERSION.dmg"
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk '{print $2}')}"
if [ -z "$SIGN_ID" ]; then
  [ -z "${CI:-}" ] || { echo "No Developer ID Application certificate in the keychain." >&2; exit 1; }
  echo "No Developer ID Application certificate: signing ad-hoc (the build only runs on this Mac)." >&2
  SIGN_ID="-"
fi
export SIGN_ID

echo "Building $VERSION (arm64)"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/T3Notch"

rm -rf "$DIST" && mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/T3Notch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Extension "$APP/Contents/Resources/Extension"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

echo "Signing"
if [ "$SIGN_ID" = "-" ]; then
  codesign --force --options runtime --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
fi
codesign --verify --deep --strict "$APP"

# The app is notarized and stapled on its own first, so a copy taken out of the DMG or the zip
# opens without a network check. The DMG is notarized again as the outer container.
if [ -n "${NOTARY_KEY_PATH:-}" ] && [ "$SIGN_ID" != "-" ]; then
  echo "Notarizing"
  ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
  xcrun notarytool submit "$DIST/notarize.zip" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" --wait
  xcrun stapler staple "$APP"
  rm "$DIST/notarize.zip"
  spctl --assess --type execute -vv "$APP"
else
  echo "NOTARY_KEY_PATH not set: skipping notarization (the app will not open cleanly elsewhere)." >&2
  unset NOTARY_KEY_PATH
fi

ditto -c -k --keepParent "$APP" "$ZIP"
scripts/make-dmg.sh "$APP" "$DMG"
cp "$DMG" "$DIST/T3-Notch.dmg"

(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" | tee "$(basename "$ZIP").sha256" \
  && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256")
echo "Done: $DMG, $ZIP"
