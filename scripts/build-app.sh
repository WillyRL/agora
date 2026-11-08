#!/bin/zsh
# Builds Agora.app into ./build. Usage: scripts/build-app.sh [debug|release]
#   AGORA_UNIVERSAL=1         build for Apple Silicon and Intel (releases)
#   AGORA_VERSION=0.2.0       version shown in Finder and About (default: Info.plist's)
#   AGORA_BUILD_NUMBER=42     build number (default: Info.plist's)
#   AGORA_SIGN_IDENTITY=…     signing identity (default: local certificate, else ad hoc)
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
ARCHS=()
[ "${AGORA_UNIVERSAL:-}" = "1" ] && ARCHS=(--arch arm64 --arch x86_64)
swift build -c "$CONFIG" --product Agora "${ARCHS[@]}"
BIN="$(swift build -c "$CONFIG" "${ARCHS[@]}" --show-bin-path)/Agora"
APP="build/Agora.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Agora"
cp scripts/Info.plist "$APP/Contents/Info.plist"
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
# A real certificate gets a secure timestamp, which notarization requires.
TIMESTAMP=(--timestamp=none)
[ "$IDENTITY" != "-" ] && [ "$IDENTITY" != "Agora Local Signing" ] && TIMESTAMP=(--timestamp)
codesign --force --deep --options runtime "${TIMESTAMP[@]}" --sign "$IDENTITY" "$APP" >/dev/null
echo "Built $APP"
