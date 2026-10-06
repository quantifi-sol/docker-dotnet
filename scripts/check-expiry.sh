#!/usr/bin/env bash
# Every patch (patches/*.patch) and overlay (overlays/*.Dockerfile) must declare
#   Reason: <why it exists, CVE id if any>
#   Expires: YYYY-MM-DD | never
# in its header. Fails when a field is missing or the expiry date has passed, so
# emergency fixes get removed once upstream catches up instead of piling up.
#
# Usage: scripts/check-expiry.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
today="$(date -u +%Y-%m-%d)"
failed=0

shopt -s nullglob
for f in "$root"/patches/*.patch "$root"/overlays/*.Dockerfile; do
  name="${f#"$root"/}"
  # Only look at the header (before the diff / first instruction).
  header="$(awk '/^(diff --git|ARG |FROM )/ { exit } { print }' "$f")"
  reason="$(sed -nE 's/^#? *Reason: *//p' <<<"$header" | head -1)"
  expires="$(sed -nE 's/^#? *Expires: *//p' <<<"$header" | head -1 | tr -d '[:space:]')"

  if [[ -z "$reason" ]]; then
    echo "::error file=$name::missing 'Reason:' header"; failed=1
  fi
  if [[ "$expires" == "never" ]]; then
    continue
  elif [[ ! "$expires" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "::error file=$name::missing or invalid 'Expires:' header (YYYY-MM-DD or never)"; failed=1
  elif [[ "$expires" < "$today" ]]; then
    echo "::error file=$name::expired on $expires -- remove it if upstream has caught up, or extend with a reason"; failed=1
  fi
done

exit "$failed"
