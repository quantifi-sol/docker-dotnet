# Patches

Changes to the upstream `dotnet/dotnet-docker` Dockerfiles that we need before
Microsoft ships them. `scripts/fetch-upstream.sh` applies every `*.patch` in this
folder (in name order) with `git apply` after checking out the pinned upstream revision.

Use a patch only when an overlay won't do. Overlays (`overlays/*.Dockerfile`) add a
layer on top of an image and never conflict with upstream, but they cannot change a
chiseled image (no shell, no apt). For chiseled variants, a patch to the
`runtime-deps` Dockerfile (for example, its chisel slice list) is the way in.

## Rules

Every patch starts with a header above the diff:

```
Reason: CVE-2026-NNNNN -- <what this changes and why we can't wait for Microsoft>
Expires: 2026-11-30

diff --git a/src/runtime-deps/8.0/noble-chiseled-extra/amd64/Dockerfile b/src/...
```

- `Expires:` is required (`YYYY-MM-DD`, or `never` for permanent policy). CI fails
  once the date has passed: remove the patch if upstream has caught up, or extend it
  with an updated reason.
- Patch every architecture directory (`amd64/` and `arm64v8/`) you build.
- A patch that stops applying after an upstream bump usually means Microsoft changed
  those lines, often to ship the same fix. Check before rebasing it.

## Making one

```bash
scripts/fetch-upstream.sh            # fresh ./upstream at the pinned revision
cd upstream
# edit src/<image>/<version>/<variant>/<arch>/Dockerfile ...
{ printf 'Reason: ...\nExpires: YYYY-MM-DD\n\n'; git diff; } > ../patches/010-cve-2026-nnnnn.patch
cd .. && scripts/fetch-upstream.sh   # confirm it applies cleanly
scripts/build-chain.sh --version 8.0 --variant noble-chiseled-extra   # build + scan locally
```
