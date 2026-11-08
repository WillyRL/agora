#!/bin/zsh
# Builds a universal Agora.app and packages it for a release: dist/Agora-<version>.dmg, .zip and SHA256SUMS.
# Usage: scripts/package-release.sh <version> [build-number]
#
# Signing and notarization happen only when these are set (as the release workflow does from secrets):
#   AGORA_SIGN_IDENTITY   "Developer ID Application: Name (TEAMID)", already in a keychain
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD   notarize with Apple and staple the ticket
# Without them the app is signed ad hoc: it runs, but macOS warns on first open.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/package-release.sh <version> [build-number]}"
BUILD="${2:-1}"
NAME="Agora-$VERSION"
DIST="dist"
rm -rf "$DIST" && mkdir -p "$DIST"

AGORA_UNIVERSAL=1 AGORA_VERSION="$VERSION" AGORA_BUILD_NUMBER="$BUILD" AGORA_SIGN_IDENTITY="${AGORA_SIGN_IDENTITY:--}" scripts/build-app.sh release
APP="build/Agora.app"
codesign --verify --strict "$APP"
lipo -info "$APP/Contents/MacOS/Agora"

notarize() {  # notarize <file>: waits for Apple's verdict
  xcrun notarytool submit "$1" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait
}
NOTARIZE=0
[ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ] && [ "${AGORA_SIGN_IDENTITY:--}" != "-" ] && NOTARIZE=1

if [ "$NOTARIZE" = 1 ]; then
  ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
  notarize "$DIST/notarize.zip"
  xcrun stapler staple "$APP"
  rm "$DIST/notarize.zip"
fi

# Zip (keeps the signature and extended attributes intact).
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$NAME.zip"

# Disk image with a shortcut to Applications to drag into.
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Agora $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DIST/$NAME.dmg" >/dev/null
rm -rf "$STAGE"
if [ "${AGORA_SIGN_IDENTITY:--}" != "-" ]; then
  codesign --force --timestamp --sign "$AGORA_SIGN_IDENTITY" "$DIST/$NAME.dmg"
fi
if [ "$NOTARIZE" = 1 ]; then
  notarize "$DIST/$NAME.dmg"
  xcrun stapler staple "$DIST/$NAME.dmg"
fi

(cd "$DIST" && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS)
echo "notarized=$NOTARIZE"
ls -la "$DIST"
