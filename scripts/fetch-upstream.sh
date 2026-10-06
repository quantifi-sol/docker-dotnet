#!/usr/bin/env bash
# Fetch dotnet/dotnet-docker at the revision pinned in upstream.env (src/ only) and
# apply our patches/*.patch on top.
#
# Usage: scripts/fetch-upstream.sh [target-dir]      (default: ./upstream)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
target="${1:-$root/upstream}"

# shellcheck source=../upstream.env
source "$root/upstream.env"
: "${UPSTREAM_REPO:?missing in upstream.env}" "${UPSTREAM_SHA:?missing in upstream.env}"

rm -rf "$target"
git init --quiet "$target"
git -C "$target" remote add origin "$UPSTREAM_REPO"
git -C "$target" sparse-checkout set src
git -C "$target" fetch --quiet --depth 1 --filter=blob:none origin "$UPSTREAM_SHA"
git -C "$target" -c advice.detachedHead=false checkout --quiet FETCH_HEAD
echo "Fetched $UPSTREAM_REPO @ $UPSTREAM_SHA -> $target"

"$root/scripts/check-expiry.sh"

shopt -s nullglob
patches=("$root"/patches/*.patch)
for p in "${patches[@]}"; do
  echo "Applying patch $(basename "$p")"
  # A patch that no longer applies usually means upstream changed (often fixed) the
  # same lines -- check whether the patch is still needed before rebasing it.
  git -C "$target" apply --verbose "$p"
done
echo "Applied ${#patches[@]} patch(es)."
