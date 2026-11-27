#!/bin/bash
# Makes the drag-to-Applications DMG from a built "T3 Notch.app": the app, a link to /Applications,
# the background from Resources/ and the app icon as the volume icon. Used by scripts/release.sh.
#
#   scripts/make-dmg.sh <app> <out.dmg>
#
# Signs the DMG when SIGN_ID is a Developer ID Application identity, and notarizes and staples it
# when NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID are set too. Without them the DMG is
# unsigned, which is enough to check the layout.
#
# dmgbuild (Python 3.10 or later) writes the Finder layout without Finder, so this also runs on a
# headless Mac. It is installed by hash from scripts/dmg-requirements.txt into a temporary venv,
# or set DMGBUILD to a dmgbuild you have.
set -euo pipefail

APP="${1:?usage: scripts/make-dmg.sh <app> <out.dmg>}"
DMG="${2:?usage: scripts/make-dmg.sh <app> <out.dmg>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGN_ID="${SIGN_ID:--}"
VOLUME_NAME="T3 Notch"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -d "$APP" ] || { echo "No app at $APP" >&2; exit 1; }

if [ -z "${DMGBUILD:-}" ]; then
  python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' \
    || { echo "dmgbuild needs Python 3.10 or later; python3 is $(python3 --version 2>&1)." >&2; exit 1; }
  python3 -m venv "$WORK/venv"
  "$WORK/venv/bin/pip" install --quiet --disable-pip-version-check --require-hashes --no-deps \
    -r "$ROOT/scripts/dmg-requirements.txt"
  DMGBUILD="$WORK/venv/bin/dmgbuild"
fi

echo "Making $DMG"
rm -f "$DMG"
"$DMGBUILD" -s "$ROOT/scripts/dmg-settings.py" \
  -D app="$APP" \
  -D background="$ROOT/Resources/dmg-background.png" \
  -D volume_icon="$APP/Contents/Resources/AppIcon.icns" \
  "$VOLUME_NAME" "$DMG"

if [ "$SIGN_ID" = "-" ]; then
  echo "No Developer ID identity: the DMG is not signed (fine for a layout check, not for release)." >&2
  exit 0
fi

echo "Signing the DMG"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"

if [ -n "${NOTARY_KEY_PATH:-}" ]; then
  echo "Notarizing the DMG"
  xcrun notarytool submit "$DMG" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature -vv "$DMG"
else
  echo "NOTARY_KEY_PATH not set: the DMG is signed but not notarized." >&2
fi
