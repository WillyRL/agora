#!/bin/zsh
# Resolves Swift packages, working around GitHub's release downloads failing now and then (504s): if
# SwiftPM can't download a binary artifact, fetch it through the GitHub API instead and put it where
# SwiftPM's cache expects it. The file must match the package's published checksum, and SwiftPM checks it too.
# Runs before every build (scripts/build-app.sh); quick when everything is already there.
set -uo pipefail
cd "$(dirname "$0")/.."
CACHE="$HOME/Library/Caches/org.swift.swiftpm/artifacts"
ARTIFACTS=(
  # owner/repo  tag  asset  sha256 (the checksum in that package's Package.swift)
  "sparkle-project/Sparkle 2.10.1 Sparkle-for-Swift-Package-Manager.zip 4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a"
)

fetch_through_api() {  # fetch_through_api <repo> <tag> <asset> <out>
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh release download "$2" -R "$1" -p "$3" -O "$4" --clobber && return 0
  fi
  local id
  id="$(curl -fsSL "https://api.github.com/repos/$1/releases/tags/$2" \
    | python3 -c "import json,sys; print(next(a['id'] for a in json.load(sys.stdin)['assets'] if a['name']==sys.argv[1]))" "$3")" || return 1
  curl -fsSL --retry 3 -H "Accept: application/octet-stream" -o "$4" "https://api.github.com/repos/$1/releases/assets/$id"
}

for attempt in 1 2 3 4; do
  swift package resolve && exit 0
  echo "Fetching Swift packages failed (attempt $attempt); getting binary artifacts through the GitHub API." >&2
  rm -rf .build/artifacts .build/workspace-state.json   # forget the half-done download
  for line in "${ARTIFACTS[@]}"; do
    read -r REPO TAG ASSET SHA <<< "$line"
    URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
    NAME="$(echo "$URL" | sed 's/[^A-Za-z0-9]/_/g')"   # how SwiftPM names its cached copy
    mkdir -p "$CACHE"
    TMP="$CACHE/.$NAME.part"
    if fetch_through_api "$REPO" "$TAG" "$ASSET" "$TMP" && [ "$(shasum -a 256 "$TMP" | cut -d' ' -f1)" = "$SHA" ]; then
      mv -f "$TMP" "$CACHE/$NAME"
    else
      echo "Couldn't get $ASSET through the API either." >&2
      rm -f "$TMP"
    fi
  done
  sleep $((attempt * 5))
done
echo "Couldn't fetch Swift packages. Check your connection to github.com and try again." >&2
exit 1
