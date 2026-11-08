#!/bin/zsh
# Builds Agora.app into ./build. Usage: scripts/build-app.sh [debug|release]
#   AGORA_UNIVERSAL=1         build for Apple Silicon and Intel (releases)
#   AGORA_VERSION=0.2.0       version shown in Finder and About (default: Info.plist's)
#   AGORA_BUILD_NUMBER=42     build number (default: Info.plist's)
#   AGORA_SIGN_IDENTITY=…     signing identity (default: local certificate, else ad hoc)
#   AGORA_UPDATE_FEED=…, AGORA_UPDATE_PUBLIC_KEY=…   turn on in-app updates (release builds)
#   AGORA_UPDATE_FEED_NIGHTLY=…                      also offer the Nightly channel
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
ARCHS=()
[ "${AGORA_UNIVERSAL:-}" = "1" ] && ARCHS=(--arch arm64 --arch x86_64)
swift build -c "$CONFIG" --product Agora "${ARCHS[@]}"
BINDIR="$(swift build -c "$CONFIG" "${ARCHS[@]}" --show-bin-path)"
APP="build/Agora.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BINDIR/Agora" "$APP/Contents/MacOS/Agora"
cp scripts/Info.plist "$APP/Contents/Info.plist"

# Sparkle (in-app updates). Agora isn't sandboxed, so Sparkle's XPC helpers aren't needed.
ditto "$BINDIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Agora"

# Release builds get the update feed and the public key that checks each update's signature.
# Builds made from source don't, so they never replace themselves with a release.
if [ -n "${AGORA_UPDATE_FEED:-}" ] && [ -n "${AGORA_UPDATE_PUBLIC_KEY:-}" ]; then
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string ${AGORA_UPDATE_FEED}" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string ${AGORA_UPDATE_PUBLIC_KEY}" "$APP/Contents/Info.plist"
  [ -n "${AGORA_UPDATE_FEED_NIGHTLY:-}" ] && /usr/libexec/PlistBuddy -c "Add :AgoraNightlyFeedURL string ${AGORA_UPDATE_FEED_NIGHTLY}" "$APP/Contents/Info.plist"
fi
[ -n "${AGORA_VERSION:-}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${AGORA_VERSION}" "$APP/Contents/Info.plist"
[ -n "${AGORA_BUILD_NUMBER:-}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${AGORA_BUILD_NUMBER}" "$APP/Contents/Info.plist"

# App icon from assets/icon.svg (rendered with Quick Look, packed with iconutil).
if [ ! -f build/AppIcon.icns ] || [ assets/icon.svg -nt build/AppIcon.icns ]; then
  TMP="$(mktemp -d)"
  qlmanage -t -s 1024 -o "$TMP" assets/icon.svg >/dev/null 2>&1 || true
  if [ -f "$TMP/icon.svg.png" ]; then
    SET="$TMP/AppIcon.iconset"; mkdir -p "$SET"
    for s in 16 32 128 256 512; do
      sips -z $s $s "$TMP/icon.svg.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
      sips -z $((s*2)) $((s*2)) "$TMP/icon.svg.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$SET" -o build/AppIcon.icns
  fi
  rm -rf "$TMP"
fi
[ -f build/AppIcon.icns ] && cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with AGORA_SIGN_IDENTITY if set, else the local certificate from scripts/make-signing-cert.sh,
# else ad hoc. Ad hoc gives every build a new identity, so the keychain asks for your password again.
IDENTITY="${AGORA_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-certificate -c "Agora Local Signing" >/dev/null 2>&1; then
  IDENTITY="Agora Local Signing"
fi
if [ -z "$IDENTITY" ]; then
  echo "Note: signing ad hoc; macOS will ask for your keychain password after each rebuild. Run scripts/make-signing-cert.sh once to stop that."
  IDENTITY="-"
fi
# A Developer ID gets the hardened runtime and a secure timestamp, which notarization requires. Ad-hoc
# and self-signed builds have no Team ID, and the hardened runtime would then refuse to load Sparkle.
OPTS=(--timestamp=none)
[[ "$IDENTITY" == "Developer ID Application:"* ]] && OPTS=(--timestamp --options runtime)
# Inside out: Sparkle's helpers, the framework, then the app (notarization rejects --deep signing).
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
for part in "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE"; do
  codesign --force "${OPTS[@]}" --sign "$IDENTITY" "$part" >/dev/null
done
codesign --force "${OPTS[@]}" --sign "$IDENTITY" "$APP" >/dev/null
echo "Built $APP"
