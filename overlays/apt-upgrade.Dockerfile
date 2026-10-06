# Reason: Pick up Ubuntu security updates published since the ubuntu:noble base
#         image was last refreshed. upstream runtime-deps only installs the .NET
#         prerequisites; packages already in the base image are never upgraded.
# Expires: never
#
# Only valid for apt-based variants (noble). Chiseled images have no apt; they get
# fresh packages because chisel downloads from the Ubuntu archive at build time.
ARG BASE
FROM ${BASE}

RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*
