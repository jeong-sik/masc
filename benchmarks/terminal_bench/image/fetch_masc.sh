#!/usr/bin/env bash
# Download the prebuilt masc server binary for both Linux architectures and
# verify each runs in a container of that architecture. No local build
# (constitution).
#
# Harbor builds a Terminal-Bench 4.0 task image from its Dockerfile for the
# Docker daemon's own architecture, and a single-architecture base image still
# runs as that one. So one run can hold arm64 and amd64 task containers, and
# the agent picks dist/linux-x64 or dist/linux-arm64 per container by
# `uname -m` (agents/masc_dist.py).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/../dist"

# Resolved, not pinned. This repository prunes old releases — the previous
# pin (0.35.8) stopped existing and the script then failed with a bare
# "release not found". Pass MASC_VERSION to hold a specific one; dist/.version
# records whichever was used, so a run stays attributable either way.
MASC_VERSION="${MASC_VERSION:-}"
if [[ -z "${MASC_VERSION}" ]]; then
  MASC_VERSION="$(gh release view -R jeong-sik/masc --json tagName --jq '.tagName' 2>/dev/null | sed 's/^v//')"
  if [[ -z "${MASC_VERSION}" ]]; then
    echo "could not resolve the latest masc release; pass MASC_VERSION=<x.y.z>" >&2
    exit 1
  fi
  echo "[fetch] latest release: v${MASC_VERSION}"
fi

# gh is uploaded only when the run passes GH_TOKEN, and is absent from debian
# stable, which many task base images use.
GH_VERSION="${GH_VERSION:-2.65.0}"

# <dist dir> <masc asset suffix> <shim and gh asset suffix> <docker platform>
ARCHES=(
  "linux-x64 x64 amd64 linux/amd64"
  "linux-arm64 arm64 arm64 linux/arm64"
)

mkdir -p "${DIST_DIR}"
for row in "${ARCHES[@]}"; do
  read -r dir masc_arch pkg_arch platform <<<"${row}"
  out="${DIST_DIR}/${dir}"
  mkdir -p "${out}"
  if ! gh release download "v${MASC_VERSION}" -R jeong-sik/masc \
       -p "masc-linux-${masc_arch}" -O "${out}/masc" --clobber; then
    echo "no masc-linux-${masc_arch} asset on v${MASC_VERSION}. Releases that exist:" >&2
    gh release list -R jeong-sik/masc --limit 5 >&2 || true
    exit 1
  fi
  # The remote_ssh exec lane invokes `masc-exec-shim` on the remote PATH; the
  # release ships it as a separate static binary.
  gh release download "v${MASC_VERSION}" -R jeong-sik/masc \
    -p "masc-exec-shim-linux-${pkg_arch}" -O "${out}/masc-exec-shim" --clobber
  curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${pkg_arch}.tar.gz" \
    | tar -xz -C "${out}" --strip-components=2 "gh_${GH_VERSION}_linux_${pkg_arch}/bin/gh"
  chmod +x "${out}/masc" "${out}/masc-exec-shim" "${out}/gh"

  # Verify by running it, and let that verdict stand. The old form was
  #   bash -c 'masc --version || masc --help | head -5'
  # whose inner shell inherits no errexit and ends in `head`, so it exits 0 for
  # a truncated download, a wrong-arch asset, or a binary missing every
  # library — while its comment claimed to verify the binary runs.
  echo "[fetch] verify ${dir} on ${platform}"
  docker run --rm --platform "${platform}" \
    -v "${out}:/opt/dist:ro" \
    ubuntu:24.04 /opt/dist/masc --version
done
printf '%s\n' "$MASC_VERSION" > "${DIST_DIR}/.version"

# Record what was downloaded. A release asset can be replaced or truncated,
# and nothing else here would notice.
( cd "${DIST_DIR}" && shasum -a 256 linux-*/masc linux-*/masc-exec-shim linux-*/gh > SHA256SUMS )
