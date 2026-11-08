#!/bin/bash
# Prints one version's section of CHANGELOG.md for its release notes, with the repo's own image paths
# turned into links that work outside the repo (release page, in-app update window), pinned to the tag.
#   scripts/changelog-notes.sh 0.2.0 [v0.2.0] [owner/repo]
# Prints nothing when the changelog has no section for that version.
set -euo pipefail
VERSION="$1"
REF="${2:-v$1}"
REPO="${3:-WillyRL/agora}"
cd "$(dirname "$0")/.."
awk -v v="$VERSION" '
    /^## / { if (found) exit; split($0, w, " "); if (w[2] == v) { found = 1; next } }
    found { print }
' CHANGELOG.md \
    | sed -E "s#(\]\(|src=\")docs/#\1https://raw.githubusercontent.com/$REPO/$REF/docs/#g" \
    | sed -e '/./,$!d' -e :a -e '/^\n*$/{$d;N;ba' -e '}'
