#!/bin/zsh
# Writes an update feed (Sparkle appcast) with one signed item for <archive>.
# Usage: scripts/make-appcast.sh <version> <build-number> <archive.zip> <download-url> <notes.html> <out.xml> [also-include.xml]
#   also-include.xml   another feed whose items are copied in (the nightly feed carries the latest stable item,
#                      so nightly users still get a newer stable release)
#   SPARKLE_BIN        folder with Sparkle's sign_update (from the Sparkle release of the same version)
#   SPARKLE_KEY_FILE   the private EdDSA key; without it, sign_update uses the key in this Mac's Keychain
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$1"; BUILD="$2"; ARCHIVE="$3"; URL="$4"; NOTES="$5"; OUT="$6"; INCLUDE="${7:-}"
REPO="${AGORA_REPO:-WillyRL/agora}"
KEY_ARGS=(--account agora-updates)
[ -n "${SPARKLE_KEY_FILE:-}" ] && KEY_ARGS=(--ed-key-file "$SPARKLE_KEY_FILE")
SIGNATURE="$("$SPARKLE_BIN/sign_update" "${KEY_ARGS[@]}" "$ARCHIVE")"   # sparkle:edSignature="…" length="…"
case "$SIGNATURE" in *edSignature=*length=*) ;; *) echo "sign_update gave no signature" >&2; exit 1 ;; esac
DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' scripts/Info.plist)"
EXTRA=""
if [ -n "$INCLUDE" ] && [ -s "$INCLUDE" ]; then
  EXTRA="$(python3 -c 'import re,sys; print("\n".join(m.group(0) for m in re.finditer(r"<item>.*?</item>", open(sys.argv[1]).read(), re.S)))' "$INCLUDE")"
fi
cat > "$OUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Agora</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Agora $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <description><![CDATA[$(cat "$NOTES")]]></description>
      <enclosure url="$URL" type="application/octet-stream" $SIGNATURE/>
    </item>
$EXTRA
  </channel>
</rss>
XML
python3 -c 'import sys,xml.dom.minidom as m; m.parse(sys.argv[1])' "$OUT"   # well-formed
echo "Wrote $OUT for $VERSION ($BUILD)"
