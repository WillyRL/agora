#!/bin/zsh
# Publishes an update feed to the `updates` branch, where installed copies read it from
# https://raw.githubusercontent.com/WillyRL/agora/updates/<file>. That address always points at the newest feed
# (pre-releases included, unlike releases/latest) and doesn't depend on GitHub's release downloads.
# Usage: scripts/publish-feed.sh <feed.xml>    (run from a clone that can push to origin)
set -euo pipefail
cd "$(dirname "$0")/.."
FEED="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
NAME="$(basename "$FEED")"
WT="$(mktemp -d)/updates"
git config user.name >/dev/null 2>&1 || git config user.name "github-actions[bot]"
git config user.email >/dev/null 2>&1 || git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
for attempt in 1 2 3 4 5; do
  rm -rf "$WT"
  if git fetch -q origin updates 2>/dev/null; then
    git worktree add -q --detach "$WT" FETCH_HEAD
  else
    git worktree add -q --detach "$WT" HEAD
    (cd "$WT" && git checkout -q --orphan updates-new && git rm -rfq . && printf '# Update feeds\n\nAgora and Agora Nightly check these files for new versions. Written by the release workflows; do not edit.\n' > README.md && git add README.md)
  fi
  cp "$FEED" "$WT/$NAME"
  (cd "$WT" && git add "$NAME" && { git diff --cached --quiet || git commit -qm "Update $NAME"; } && git push -q origin HEAD:refs/heads/updates) && { git worktree remove --force "$WT"; echo "Published $NAME"; exit 0; }
  git worktree remove --force "$WT" || true
  sleep $((attempt * 3))   # someone else published at the same moment: start again from theirs
done
echo "Couldn't publish $NAME" >&2
exit 1
