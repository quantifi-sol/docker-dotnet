#!/usr/bin/env bash
# Show which build a published tag points at, per architecture, from the image labels
# set by build-chain.sh.
#
# Usage: scripts/show-build.sh docker.io/quantifisol/dotnet-aspnet:8.0-noble-chiseled-extra
set -euo pipefail
ref="${1:?usage: $0 <image:tag>}"

echo "$ref"
docker buildx imagetools inspect "$ref" --format '{{json .Image}}' | jq -r '
  # A multi-arch tag gives {platform: image}; a single-arch one gives the image itself.
  (if has("config") then {"single-arch": .} else . end) | to_entries[]
  | .value.config.Labels as $l
  | "  \(.key)",
    "    build tag : \($l["dotnet-docker.build.tag"] // "?")",
    "    created   : \($l["org.opencontainers.image.created"] // "?")",
    "    version   : \($l["org.opencontainers.image.version"] // "?")",
    "    upstream  : \($l["dotnet-docker.upstream.revision"] // "?")",
    "    patches   : \(($l["dotnet-docker.patches"] // "") | if . == "" then "none" else . end)",
    "    run       : \($l["dotnet-docker.build.url"] // "?")"'
