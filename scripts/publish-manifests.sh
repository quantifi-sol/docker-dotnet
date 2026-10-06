#!/usr/bin/env bash
# Combine the per-architecture images pushed by build-chain.sh into multi-arch tags.
#
# For every image in every build record it publishes:
#   <prefix><image>:<major>-<variant>              e.g. dotnet-aspnet:8.0-noble-chiseled-extra
#   <prefix><image>:<full>-<variant>               e.g. dotnet-aspnet:8.0.31-noble-chiseled-extra
#   <prefix><image>:<major>-<variant>-<stamp>      e.g. dotnet-aspnet:8.0-noble-chiseled-extra-20261004-57 (immutable)
#
# Usage: scripts/publish-manifests.sh --records <dir containing */build.json> --push-prefix docker.io/quantifisol/dotnet-
# (same prefix as build-chain.sh; it is prepended verbatim to the image name)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
records="" push_prefix=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --records)     records="$2"; shift 2 ;;
    --push-prefix) push_prefix="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
: "${records:?--records is required}" "${push_prefix:?--push-prefix is required}"

# One line per (version, variant, image) with the digest of each architecture.
all="$(find "$records" -name build.json -print0 | xargs -0 cat | jq -s -c '
  [ .[] as $b | $b.images[] | {version: $b.version, variant: $b.variant, stamp: $b.stamp,
      arch: $b.arch, name, fullVersion, digest} ]
  | group_by([.version, .variant, .name]) | .[]')"
[[ -n "$all" ]] || { echo "no build records under $records" >&2; exit 1; }

expected_arches="$(jq -r '[.architectures[].name] | sort | join(",")' "$root/images.json")"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
printf '### Published images\n\n| Image | Tags |\n|---|---|\n' >>"$summary"

while IFS= read -r group; do
  name="$(jq -r '.[0].name' <<<"$group")"
  version="$(jq -r '.[0].version' <<<"$group")"
  variant="$(jq -r '.[0].variant' <<<"$group")"
  stamp="$(jq -r '.[0].stamp' <<<"$group")"
  full="$(jq -r '.[0].fullVersion' <<<"$group")"
  arches="$(jq -r '[.[].arch] | sort | join(",")' <<<"$group")"

  [[ "$arches" == "$expected_arches" ]] \
    || { echo "$name $version-$variant: have [$arches], need [$expected_arches]" >&2; exit 1; }
  [[ "$(jq '[.[].fullVersion] | unique | length' <<<"$group")" == 1 ]] \
    || { echo "$name $version-$variant: architectures disagree on version" >&2; exit 1; }
  [[ "$(jq '[.[].stamp] | unique | length' <<<"$group")" == 1 ]] \
    || { echo "$name $version-$variant: build records from different runs" >&2; exit 1; }

  sources=()
  repo="$push_prefix$name"
  while IFS= read -r d; do sources+=("$repo@$d"); done < <(jq -r '.[].digest' <<<"$group")

  tags=("$version-$variant" "$full-$variant" "$version-$variant-$stamp")
  tag_args=()
  for t in "${tags[@]}"; do tag_args+=(--tag "$repo:$t"); done

  echo "Publishing $repo: ${tags[*]}"
  docker buildx imagetools create "${tag_args[@]}" "${sources[@]}"
  echo "| \`$repo\` | \`${tags[*]}\` |" >>"$summary"
done <<<"$all"
