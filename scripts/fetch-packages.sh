#!/bin/zsh
# Resolves Swift packages, working around GitHub's release downloads failing now and then (504s): if
# SwiftPM can't download a binary artifact, fetch it through the GitHub API instead (gh) and put it where
# SwiftPM's cache expects it. SwiftPM still checks it against the package's published checksum.
set -uo pipefail
cd "$(dirname "$0")/.."
CACHE="$HOME/Library/Caches/org.swift.swiftpm/artifacts"
ARTIFACTS=(
  # owner/repo  tag  asset
  "sparkle-project/Sparkle 2.10.1 Sparkle-for-Swift-Package-Manager.zip"
)
for attempt in 1 2 3 4; do
  swift package resolve && exit 0
  echo "Resolving failed (attempt $attempt); fetching binary artifacts through the GitHub API." >&2
  rm -rf .build/artifacts .build/workspace-state.json   # forget the half-done download
  for line in "${ARTIFACTS[@]}"; do
    read -r REPO TAG ASSET <<< "$line"
    URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
    NAME="$(echo "$URL" | sed 's/[^A-Za-z0-9]/_/g')"   # how SwiftPM names its cached copy
    mkdir -p "$CACHE"
    rm -f "$CACHE/$NAME"
    gh release download "$TAG" -R "$REPO" -p "$ASSET" -O "$CACHE/$NAME" --clobber || rm -f "$CACHE/$NAME"
  done
  sleep $((attempt * 10))
done
exit 1
