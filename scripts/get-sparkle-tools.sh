#!/bin/zsh
# Downloads Sparkle's command-line tools (sign_update…) into <dir>/bin, checked against a pinned checksum.
# Keep the version in step with Sparkle in Package.resolved.
# Usage: scripts/get-sparkle-tools.sh <dir>
set -euo pipefail
VERSION="2.10.1"
SHA256="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
DIR="${1:?usage: scripts/get-sparkle-tools.sh <dir>}"
cd "$(dirname "$0")/.."
RESOLVED="$(python3 -c 'import json;print(next(p["state"].get("version","") for p in json.load(open("Package.resolved"))["pins"] if p["identity"]=="sparkle"))')"
[ "$RESOLVED" = "$VERSION" ] || echo "warning: Package.resolved has Sparkle $RESOLVED, tools are $VERSION" >&2
mkdir -p "$DIR"
curl -fsSL --retry 4 --retry-all-errors -o "$DIR/sparkle.tar.xz" "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" \
  || gh release download "$VERSION" -R sparkle-project/Sparkle -p "Sparkle-$VERSION.tar.xz" -O "$DIR/sparkle.tar.xz" --clobber
echo "$SHA256  $DIR/sparkle.tar.xz" | shasum -a 256 -c - >/dev/null
tar -xf "$DIR/sparkle.tar.xz" -C "$DIR"
rm "$DIR/sparkle.tar.xz"
echo "$DIR/bin"
