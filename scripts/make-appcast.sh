#!/bin/zsh
# Writes an update feed (Sparkle appcast) with one signed item for <archive>.
# Usage: scripts/make-appcast.sh <version> <build-number> <archive.zip> <download-url> <notes.html> <out.xml> [current.xml]
#   current.xml        the feed as published now: its items on other channels are kept, so the stable feed
#                      carries the latest stable release and the latest beta side by side
#   SPARKLE_CHANNEL    "beta" marks the new item as a beta (only betas install those); empty for stable
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
CHANNEL="${SPARKLE_CHANNEL:-}"
CHANNEL_TAG=""
[ -n "$CHANNEL" ] && CHANNEL_TAG="<sparkle:channel>$CHANNEL</sparkle:channel>"
EXTRA=""
if [ -n "$INCLUDE" ] && [ -s "$INCLUDE" ]; then
  # Keep the items on other channels; this one replaces the previous item on its own channel.
  EXTRA="$(python3 - "$INCLUDE" "$CHANNEL" <<'PY'
import re, sys
feed, channel = open(sys.argv[1]).read(), sys.argv[2]
for item in re.findall(r"<item>.*?</item>", feed, re.S):
    m = re.search(r"<sparkle:channel>(.*?)</sparkle:channel>", item)
    if (m.group(1) if m else "") != channel:
        print(item)
PY
)"
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
      $CHANNEL_TAG
      <description><![CDATA[$(cat "$NOTES")]]></description>
      <enclosure url="$URL" type="application/octet-stream" $SIGNATURE/>
    </item>
$EXTRA
  </channel>
</rss>
XML
python3 -c 'import sys,xml.dom.minidom as m; m.parse(sys.argv[1])' "$OUT"   # well-formed
echo "Wrote $OUT for $VERSION ($BUILD)"
