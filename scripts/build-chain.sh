#!/usr/bin/env bash
# Build one image chain (e.g. 8.0 / noble-chiseled-extra: runtime-deps -> runtime ->
# aspnet) for one architecture from the upstream dotnet/dotnet-docker Dockerfiles,
# apply overlays, smoke-test, scan, and optionally push.
#
# Nothing is pushed unless EVERY image in the chain passes the scan gate.
#
# Usage:
#   scripts/build-chain.sh --version 8.0 --variant noble-chiseled-extra \
#       [--arch amd64|arm64] [--upstream ./upstream] [--no-scan] \
#       [--push-prefix docker.io/quantifisol/dotnet- --stamp 20261004-12] [--dry-run]
#
# --push-prefix is prepended verbatim to the image name, so it decides the layout:
#   docker.io/quantifisol/dotnet-  -> docker.io/quantifisol/dotnet-aspnet   (Docker Hub: no nesting)
#   ghcr.io/<owner>/dotnet/        -> ghcr.io/<owner>/dotnet/aspnet
#
# --dry-run resolves the Dockerfiles, versions and chained tags and prints the plan
# without touching docker (handy after bumping upstream or adding a variant).
#
# Requires: docker (with buildx), jq, trivy (unless --no-scan).
# Run scripts/fetch-upstream.sh first.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
version="" variant="" arch="" upstream="$root/upstream" scan=1 push_prefix="" stamp="" dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)     version="$2"; shift 2 ;;
    --variant)     variant="$2"; shift 2 ;;
    --arch)        arch="$2"; shift 2 ;;
    --upstream)    upstream="$2"; shift 2 ;;
    --no-scan)     scan=0; shift ;;
    --push-prefix) push_prefix="$2"; shift 2 ;;
    --stamp)       stamp="$2"; shift 2 ;;
    --dry-run)     dry_run=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

: "${version:?--version is required}" "${variant:?--variant is required}"
if [[ -z "$arch" ]]; then
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; arm64|aarch64) arch=arm64 ;; *) echo "unsupported host arch" >&2; exit 2 ;; esac
fi
stamp="${stamp:-$(date -u +%Y%m%d)-local}"
platform="linux/$arch"

# shellcheck source=../upstream.env
source "$root/upstream.env"

build="$(jq -ce --arg v "$version" --arg n "$variant" '.builds[] | select(.version == $v and .variant == $n)' "$root/images.json")" \
  || { echo "no build '$version/$variant' in images.json" >&2; exit 2; }
arch_dir="$(jq -re --arg a "$arch" '.architectures[] | select(.name == $a) | .upstreamDir' "$root/images.json")" \
  || { echo "no architecture '$arch' in images.json" >&2; exit 2; }
images=()
while IFS= read -r i; do images+=("$i"); done < <(jq -r '.images[]' <<<"$build")

local_repo="local/dotnet"
local_tag="$version-$variant-$arch"
key="$version-$variant-$arch"
out="$root/out/$key"

dockerfile() { echo "$upstream/src/$1/$version/$variant/$arch_dir/Dockerfile"; }

# Product version an image is published under (matches Microsoft's tag scheme:
# runtime-deps carries the runtime version, sdk the SDK version).
full_version() {
  local file var
  case "$1" in
    runtime-deps|runtime) file="$upstream/src/runtime/$version/$variant/$arch_dir/Dockerfile"; var=DOTNET_VERSION ;;
    aspnet)               file="$(dockerfile aspnet)"; var=ASPNET_VERSION ;;
    sdk)                  file="$(dockerfile sdk)"; var=DOTNET_SDK_VERSION ;;
    *) echo "unknown image $1" >&2; return 1 ;;
  esac
  sed -nE "s/.*[^A-Za-z_]$var=([0-9][0-9A-Za-z.-]*).*/\1/p" "$file" | head -1
}

for img in "${images[@]}"; do
  [[ -f "$(dockerfile "$img")" ]] || { echo "missing $(dockerfile "$img") -- did upstream rename the variant?" >&2; exit 1; }
done

# The next upstream Dockerfile in the chain does `FROM $REPO:<exact tag>`.
expected_tag() { sed -nE 's/^FROM \$REPO:([^ ]+).*/\1/p' "$(dockerfile "$1")" | head -1; }

if [[ $dry_run -eq 1 ]]; then
  echo "Plan for $key (upstream $UPSTREAM_SHA):"
  for idx in "${!images[@]}"; do
    img="${images[$idx]}"
    next="${images[$((idx + 1))]:-}"
    printf '  %-12s %-10s %s\n' "$img" "$(full_version "$img")" "$(dockerfile "$img" | sed "s|^$upstream/||")"
    overlays="$(jq -r --arg i "$img" '(.overlays[$i] // []) | join(", ")' <<<"$build")"
    [[ -z "$overlays" ]] || echo "               overlays: $overlays"
    [[ -z "$next" ]] || echo "               tagged for $next as: $(expected_tag "$next")"
  done
  exit 0
fi

# Use the docker-driver builder of the current context so each build can FROM the
# image built in the previous step straight from the local image store.
builder="${BUILDX_BUILDER:-$(docker context show)}"
rm -rf "$out" && mkdir -p "$out"

patches=""
for p in "$root"/patches/*.patch; do
  if [[ -e "$p" ]]; then patches="${patches:+$patches,}$(basename "$p")"; fi
done
repo_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-quantifisolutionsinc/platform-docker-dotnet}"
revision="${GITHUB_SHA:-$(git -C "$root" rev-parse HEAD 2>/dev/null || echo unknown)}"
created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Lets anyone holding an image find the Actions run (and its build record) that made it.
run_url="${GITHUB_RUN_ID:+$repo_url/actions/runs/$GITHUB_RUN_ID}"
run_url="${run_url:-local build}"

echo "::group::Pull base images ($platform)"
: >"$out/base-images.txt"
for img in "${images[@]}"; do
  awk 'toupper($1) == "FROM" { print $2 }' "$(dockerfile "$img")"
done | grep -v -e '^\$' -e '^scratch$' | sort -u | while read -r ref; do
  docker pull --quiet --platform "$platform" "$ref" >/dev/null
  digest="$(docker image inspect --format '{{join .RepoDigests " "}}' "$ref" | tr ' ' '\n' | head -1)"
  echo "$ref $digest" | tee -a "$out/base-images.txt"
done
echo "::endgroup::"

prev=""
for idx in "${!images[@]}"; do
  img="${images[$idx]}"
  df="$(dockerfile "$img")"
  ver="$(full_version "$img")"
  overlays="$(jq -r --arg i "$img" '(.overlays[$i] // []) | join(",")' <<<"$build")"
  echo "::group::Build $img $ver ($variant, $arch)"

  build_args=()
  [[ -n "$prev" ]] && build_args+=(--build-arg "REPO=$local_repo/$prev")
  docker buildx build --builder "$builder" --platform "$platform" --load \
    --file "$df" ${build_args[@]+"${build_args[@]}"} \
    --label "org.opencontainers.image.source=$repo_url" \
    --label "org.opencontainers.image.revision=$revision" \
    --label "org.opencontainers.image.version=$ver" \
    --label "dotnet-docker.upstream.revision=$UPSTREAM_SHA" \
    --label "dotnet-docker.patches=$patches" \
    --label "dotnet-docker.overlays=$overlays" \
    --label "org.opencontainers.image.created=$created" \
    --label "dotnet-docker.build.tag=$version-$variant-$stamp" \
    --label "dotnet-docker.build.url=$run_url" \
    --tag "$local_repo/$img:$local_tag" \
    "$(dirname "$df")"

  for o in ${overlays//,/ }; do
    echo "Applying overlay $o"
    docker buildx build --builder "$builder" --platform "$platform" --load \
      --file "$root/overlays/$o.Dockerfile" \
      --build-arg "BASE=$local_repo/$img:$local_tag" \
      --tag "$local_repo/$img:$local_tag" \
      "$root/overlays"
  done

  # The next upstream Dockerfile does `FROM $REPO:<exact tag>`; give it that tag.
  next_idx=$((idx + 1))
  if [[ $next_idx -lt ${#images[@]} ]]; then
    docker tag "$local_repo/$img:$local_tag" "$local_repo/$img:$(expected_tag "${images[$next_idx]}")"
  fi
  prev="$img"
  echo "::endgroup::"
done

echo "::group::Smoke tests"
for img in "${images[@]}"; do
  ver="$(full_version "$img")"
  ref="$local_repo/$img:$local_tag"
  case "$img" in
    runtime-deps) continue ;;  # no dotnet, and chiseled has no shell
    runtime|aspnet)
      runtimes="$(docker run --rm --platform "$platform" --entrypoint /usr/bin/dotnet "$ref" --list-runtimes)"
      echo "$runtimes"
      grep -q " $ver " <<<"$runtimes" || { echo "$img: runtime $ver not found" >&2; exit 1; } ;;
    sdk)
      actual="$(docker run --rm --platform "$platform" --entrypoint /usr/bin/dotnet "$ref" --version)"
      [[ "$actual" == "$ver" ]] || { echo "sdk: expected $ver, got $actual" >&2; exit 1; } ;;
  esac
  echo "$img OK"
done
echo "::endgroup::"

# Scan policy -- block only on what a rebuild or patch here can fix:
#   gate (blocking):   OS packages (TRIVY_GATE_PKG_TYPES, default "os"). Ubuntu ships the
#                      fix, we rebuild. Accepted risks go in .trivyignore (with exp:).
#   report (warning):  .NET libraries inside Microsoft's runtime/SDK tarballs. Only a new
#                      .NET/SDK release fixes those, and it arrives via the upstream bump
#                      PR; blocking on them would also block an urgent OS-CVE rebuild.
#                      Consuming apps' own image scans still gate on shipped libraries.
# Both use HIGH/CRITICAL + --ignore-unfixed, matching toolkit-app-mcp.
if [[ $scan -eq 1 ]]; then
  gate_types="${TRIVY_GATE_PKG_TYPES:-os}"
  severity="${TRIVY_SEVERITY:-HIGH,CRITICAL}"
  common=(--quiet --scanners vuln --severity "$severity" --ignore-unfixed --ignorefile "$root/.trivyignore")
  gate_failed=0
  for img in "${images[@]}"; do
    ref="$local_repo/$img:$local_tag"
    echo "::group::Scan $img"
    trivy image --quiet --scanners vuln --format cyclonedx --output "$out/$img.sbom.cdx.json" "$ref"

    if ! trivy image "${common[@]}" --pkg-types "$gate_types" --exit-code 1 "$ref" | tee "$out/$img.gate.txt"; then
      echo "::error::$img ($key) failed the vulnerability gate ($gate_types packages)"
      gate_failed=1
    fi

    if [[ ",$gate_types," != *",library,"* ]]; then
      trivy image "${common[@]}" --pkg-types library --format json --output "$out/$img.library.json" "$ref"
      findings="$(jq -r '[.Results[]? | .Vulnerabilities[]?
          | "\(.VulnerabilityID)  \(.PkgName) \(.InstalledVersion) (fixed in \(.FixedVersion))"]
        | unique | .[]' "$out/$img.library.json")"
      if [[ -n "$findings" ]]; then
        echo "::warning::$img ($key): $(wc -l <<<"$findings" | tr -d ' ') .NET library finding(s) in Microsoft-shipped components (not blocking; needs a newer .NET/SDK release -- see $img.library.json)"
        sed 's/^/    /' <<<"$findings"
      else
        echo ".NET libraries: no fixable $severity findings"
      fi
    fi
    echo "::endgroup::"
  done
  [[ $gate_failed -eq 0 ]] || { echo "Scan gate failed -- nothing pushed." >&2; exit 1; }
else
  echo "::warning::Scan skipped (--no-scan)"
fi

records=()
for img in "${images[@]}"; do
  ver="$(full_version "$img")"
  digest=""
  arch_tag=""
  if [[ -n "$push_prefix" ]]; then
    arch_tag="$push_prefix$img:$version-$variant-$stamp-$arch"
    docker tag "$local_repo/$img:$local_tag" "$arch_tag"
    docker push --quiet "$arch_tag"
    # Ask the registry rather than the local store: docker shortens docker.io names in
    # RepoDigests, and the containerd image store may push an index instead of a manifest.
    digest="$(docker buildx imagetools inspect "$arch_tag" --format '{{json .Manifest}}' | jq -r .digest)"
    [[ "$digest" == sha256:* ]] || { echo "could not resolve pushed digest for $arch_tag" >&2; exit 1; }
    echo "Pushed $arch_tag ($digest)"
  fi
  records+=("$(jq -nc --arg name "$img" --arg ver "$ver" --arg tag "$arch_tag" --arg digest "$digest" \
    '{name: $name, fullVersion: $ver, archTag: $tag, digest: $digest}')")
done

printf '%s\n' "${records[@]}" | jq -s \
  --arg version "$version" --arg variant "$variant" --arg arch "$arch" --arg stamp "$stamp" \
  --arg upstream "$UPSTREAM_SHA" --arg revision "$revision" --arg patches "$patches" \
  --rawfile bases "$out/base-images.txt" \
  '{version: $version, variant: $variant, arch: $arch, stamp: $stamp,
    upstreamRevision: $upstream, revision: $revision,
    patches: ($patches | split(",") | map(select(. != ""))),
    baseImages: ($bases | split("\n") | map(select(. != "") | split(" ") | {ref: .[0], digest: .[1]})),
    images: .}' >"$out/build.json"

echo "Build record: $out/build.json"
