# platform-docker-dotnet

Our own builds of the .NET 8 and .NET 10 container images, made from Microsoft's
[`dotnet/dotnet-docker`](https://github.com/dotnet/dotnet-docker) Dockerfiles, so we can
ship OS security fixes **as soon as Ubuntu publishes them** instead of waiting for
Microsoft to rebuild `mcr.microsoft.com/dotnet/*`.

This is not a fork. The repo holds only a pinned upstream revision, a build config,
and our (rare, short-lived) patches. The workflow checks out upstream at build time.

## What gets built

| Version | Variant | Images | Notes |
|---|---|---|---|
| 8.0, 10.0 | `noble` | runtime-deps, runtime, aspnet, sdk | Ubuntu 24.04, with `apt-upgrade` overlay |
| 8.0, 10.0 | `noble-chiseled-extra` | runtime-deps, runtime, aspnet | Distroless (no shell/apt), what toolkit-app-mcp runs on |

Each one is built for `linux/amd64` and `linux/arm64` (Apple Silicon Macs pull the arm64
image automatically). Edit [`images.json`](images.json) to add or remove variants. Any
folder under upstream `src/<image>/<version>/` works, e.g. `noble-chiseled`.

## Tags

Published to Docker Hub as `quantifisol/dotnet-<image>`. Docker Hub has no nested repos,
so there are four repos: `dotnet-runtime-deps`, `dotnet-runtime`, `dotnet-aspnet`, `dotnet-sdk`.
To publish somewhere else, set the `IMAGE_PREFIX` repo variable (e.g. `ghcr.io/<owner>/dotnet/`).

| Tag | Example | Moves? |
|---|---|---|
| `<major>-<variant>` | `dotnet-aspnet:8.0-noble-chiseled-extra` | every build |
| `<full>-<variant>` | `dotnet-aspnet:8.0.31-noble-chiseled-extra` | rebuilds within a .NET patch |
| `<major>-<variant>-<date>-<run>` | `dotnet-aspnet:8.0-noble-chiseled-extra-20261004-57` | never |
| `…-<arch>` | `…-20261004-57-amd64` | internal per-architecture inputs to the tags above; don't use |

Switching an app is a one-line change:

```dockerfile
# FROM mcr.microsoft.com/dotnet/aspnet:8.0-noble-chiseled-extra
FROM quantifisol/dotnet-aspnet:8.0-noble-chiseled-extra
```

For production, pin the digest and let Renovate/Dependabot bump it when the tag moves:
`FROM quantifisol/dotnet-aspnet:8.0-noble-chiseled-extra@sha256:…` (use the multi-arch
digest: `docker buildx imagetools inspect <image:tag> --format '{{.Manifest.Digest}}'`).
`make latest` shows which build a tag currently points at.

## How it works

```
upstream.env ──► fetch-upstream.sh ──► patches/*.patch ──► build-chain.sh (per version/variant/arch)
 (pinned SHA)    (src/ only)           (git apply)          runtime-deps ─► overlays ─► runtime ─► aspnet ─► sdk
                                                            smoke test ─► Trivy gate ─► push per-arch
                                                                                           │
                                       publish-manifests.sh ◄── all chains passed ◄────────┘
                                       (multi-arch tags)
```

- **Chaining:** each upstream Dockerfile does `FROM $REPO:<tag>`. `build-chain.sh` points
  `REPO` at the image it just built locally and tags it with exactly the tag the next
  Dockerfile expects, so upstream files are used unmodified.
- **Fresh packages:** chiseled images get current Ubuntu packages because chisel downloads
  from the archive at build time. Apt-based images get them through the
  [`apt-upgrade`](overlays/apt-upgrade.Dockerfile) overlay (upstream only installs the
  .NET prerequisites and never upgrades the base image).
- **Gate:** Trivy (same version and settings as toolkit-app-mcp: HIGH/CRITICAL,
  `--ignore-unfixed`, `.trivyignore` with `exp:`) scans every image.
  - **OS packages block.** A rebuild or patch here can fix them. Nothing is pushed unless
    the whole chain passes, and multi-arch tags only move when every architecture passed.
  - **.NET libraries block on CRITICAL, warn on HIGH.** These are NuGet packages inside
    Microsoft's runtime/SDK tarballs (e.g. MSBuild or `dotnet-format` dependencies in the
    SDK). Only a new .NET/SDK release fixes them, and it arrives through the upstream bump
    PR. Findings are listed in `<image>.library.json`. If a critical library CVE would hold
    up an urgent OS-CVE rebuild, add an expiring `.trivyignore` entry. Set
    `TRIVY_BLOCK_LIBRARY_SEVERITY=` (empty) to only report them, or
    `TRIVY_GATE_PKG_TYPES=os,library` to block on HIGH too.
  - **Unfixed CRITICALs are reported, not blocking.** `--ignore-unfixed` keeps the gates
    to what a rebuild can fix; CRITICAL findings with no released fix show as warnings
    plus `<image>.unfixed.json`, for a reachability check.
- **Published images are re-scanned daily** ([`scan-published.yml`](.github/workflows/scan-published.yml)):
  every published tag, both architectures, failing on any fixable CRITICAL (OS or
  library). That catches CVEs disclosed after an image shipped; a red run means rebuild.
- **Records:** each run uploads `build.json` (upstream revision, patches, base image
  digests, pushed digests), CycloneDX SBOMs and scan output as artifacts.

### Triggers

| Trigger | Builds | Publishes |
|---|---|---|
| Weekly (Mon 05:00 UTC) | everything | yes |
| Push to `main` touching build inputs | everything | yes |
| Pull request | everything | no |
| **Run workflow** (manual) | everything, or `only: 8.0` / `8.0/noble-chiseled-extra` | yes on `main` |
| `bump-upstream.yml` (Mon 04:00 UTC) | opens/refreshes a PR bumping `UPSTREAM_SHA` and starts a build on it | no |
| `scan-published.yml` (daily 06:00 UTC) | nothing: scans the published tags, fails on fixable CRITICALs | no |

## CVE runbook

A CVE usually shows up as a failed *Scan published .NET images* run or a failed build gate.

1. **Find out who has to ship the fix.** Look up the CVE on the
   [Ubuntu CVE tracker](https://ubuntu.com/security/cves) for `noble`.
   - **Released** in Ubuntu: go to step 2. This is the case we built this for.
   - **Needed / deferred** (no Ubuntu fix): rebuilding can't help. Assess
     reachability and add an expiring `.trivyignore` entry, as toolkit-app-mcp does.
   - **In .NET itself** (runtime/ASP.NET Core, or a NuGet library Microsoft ships): wait
     for Microsoft's servicing release; it arrives through the weekly bump PR. A CRITICAL
     one blocks our builds meanwhile, so add an expiring `.trivyignore` entry if a
     rebuild is needed before then.
2. **Rebuild:** Actions → *Build .NET images* → *Run workflow* on `main`, with
   `reason: CVE-…` and optionally `only: 8.0/noble-chiseled-extra`. The scan output in
   the run confirms the package version changed.
3. **Roll out:** rebuild the app images (they use the floating tag), or bump the pinned
   dated tag.
4. **Only if a rebuild isn't enough** (e.g. you need a specific package version, or a
   chisel slice change), add a patch (see [patches/README.md](patches/README.md)) or an
   overlay, both with `Reason:` and `Expires:` headers. CI fails when they expire.
5. Remove the matching `.trivyignore` entry in the consuming repo.

## Local build

Needs Docker (with buildx), `jq`, and `trivy`. On a Mac this builds arm64 natively.

```bash
make                                         # list targets
make plan                                    # dry-run every chain (no docker needed)
make build                                   # 8.0 noble-chiseled-extra: build, smoke-test, scan
make build VERSION=10.0 VARIANT=noble SCAN=0 # another chain, skip Trivy
make info IMAGE=aspnet                       # dotnet --info in the built image
make check                                   # expiry + script lint (run before pushing)
```

`make` only re-fetches upstream when `upstream.env` or a patch changes (`make fetch` forces it).
The Makefile is a thin wrapper; CI calls the `scripts/` directly.

## Trade-offs to keep in mind

- If upstream renames a variant (e.g. `noble` → `resolute`), the build fails loudly with
  "missing Dockerfile -- did upstream rename the variant?". Update `images.json`.
- The full matrix is 8 chains (28 image builds) running in parallel. A CVE rebuild of one
  variant (`only:`) is just 2 chains.
