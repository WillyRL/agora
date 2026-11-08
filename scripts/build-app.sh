#!/bin/zsh
# Builds an Agora app bundle into ./build.
# Usage: scripts/build-app.sh [dev|stable|nightly]
#   dev (default)  "Agora Dev.app"  io.github.willyrl.agora.dev      for working on Agora
#   stable         "Agora.app"      io.github.willyrl.agora          what releases ship
#   nightly        "Agora Nightly.app" io.github.willyrl.agora.nightly
# Each flavor is its own app (settings, saved logins), so all three install side by side.
#   AGORA_CONFIG=debug        a debug build (default: release)
#   AGORA_UNIVERSAL=1         build for Apple Silicon and Intel (releases)
#   AGORA_VERSION=0.2.0       version shown in Finder and About (default: Info.plist's)
#   AGORA_BUILD_NUMBER=42     build number (default: Info.plist's)
#   AGORA_SIGN_IDENTITY=…     signing identity (default: local certificate, else ad hoc)
#   AGORA_UPDATE_FEED=…, AGORA_UPDATE_PUBLIC_KEY=…   turn on in-app updates (release builds)
set -euo pipefail
cd "$(dirname "$0")/.."
FLAVOR="${1:-dev}"
case "$FLAVOR" in
  stable)  NAME="Agora";         BUNDLE_ID="io.github.willyrl.agora";         BADGE="" ;;
  nightly) NAME="Agora Nightly"; BUNDLE_ID="io.github.willyrl.agora.nightly"; BADGE="NIGHTLY:#0f172a" ;;
  dev)     NAME="Agora Dev";     BUNDLE_ID="io.github.willyrl.agora.dev";     BADGE="DEV:#ea580c" ;;
  *) echo "usage: scripts/build-app.sh [dev|stable|nightly]" >&2; exit 2 ;;
esac
CONFIG="${AGORA_CONFIG:-release}"
ARCHS=()
[ "${AGORA_UNIVERSAL:-}" = "1" ] && ARCHS=(--arch arm64 --arch x86_64)
swift build -c "$CONFIG" --product Agora "${ARCHS[@]}"
BINDIR="$(swift build -c "$CONFIG" "${ARCHS[@]}" --show-bin-path)"
APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BINDIR/Agora" "$APP/Contents/MacOS/Agora"
PLIST="$APP/Contents/Info.plist"
cp scripts/Info.plist "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" -c "Set :CFBundleName $NAME" -c "Set :CFBundleDisplayName $NAME" "$PLIST"
[ -n "${AGORA_VERSION:-}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${AGORA_VERSION}" "$PLIST"
[ -n "${AGORA_BUILD_NUMBER:-}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${AGORA_BUILD_NUMBER}" "$PLIST"

# App icon from assets/icon.svg (rendered with Quick Look, packed with iconutil); Nightly and Dev get a
# band across the bottom so they're easy to tell apart in the Dock.
ICNS="build/AppIcon-$FLAVOR.icns"
if [ ! -f "$ICNS" ] || [ assets/icon.svg -nt "$ICNS" ] || [ "$0" -nt "$ICNS" ]; then
  TMP="$(mktemp -d)"
  SVG="$TMP/icon.svg"
  if [ -n "$BADGE" ]; then
    LABEL="${BADGE%%:*}"; COLOR="${BADGE#*:}"
    sed "s|</svg>|<clipPath id=\"r\"><rect width=\"64\" height=\"64\" rx=\"14\"/></clipPath><rect y=\"47\" width=\"64\" height=\"17\" fill=\"$COLOR\" clip-path=\"url(#r)\"/><text x=\"32\" y=\"55.5\" dy=\"0.35em\" text-anchor=\"middle\" font-family=\"-apple-system, sans-serif\" font-size=\"8\" font-weight=\"800\" letter-spacing=\"0.6\" fill=\"#ffffff\">$LABEL</text></svg>|" assets/icon.svg > "$SVG"
  else
    cp assets/icon.svg "$SVG"
  fi
  qlmanage -t -s 1024 -o "$TMP" "$SVG" >/dev/null 2>&1 || true
  if [ -f "$TMP/icon.svg.png" ]; then
    SET="$TMP/AppIcon.iconset"; mkdir -p "$SET"
    for s in 16 32 128 256 512; do
      sips -z $s $s "$TMP/icon.svg.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
      sips -z $((s*2)) $((s*2)) "$TMP/icon.svg.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$SET" -o "$ICNS"
  fi
  rm -rf "$TMP"
fi
[ -f "$ICNS" ] && cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

# Sparkle (in-app updates). Agora isn't sandboxed, so Sparkle's XPC helpers aren't needed.
ditto "$BINDIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Agora"

# Release builds get the update feed and the public key that checks each update's signature.
# Builds made from source don't, so they never replace themselves with a release.
if [ -n "${AGORA_UPDATE_FEED:-}" ] && [ -n "${AGORA_UPDATE_PUBLIC_KEY:-}" ]; then
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string ${AGORA_UPDATE_FEED}" "$PLIST"
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string ${AGORA_UPDATE_PUBLIC_KEY}" "$PLIST"
fi

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
