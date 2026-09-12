#!/usr/bin/env bash
# Download the pinned prebuilt masc server binary and verify it runs in a
# linux container of the target architecture. No local build (constitution).
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

# The architecture of the *task images*, not of this host. Terminal-Bench
# publishes amd64 images only, so on an Apple Silicon machine docker runs them
# emulated and an arm64 masc cannot execute inside them at all — which reads
# as "missing shared libraries" three layers later.
ARCH="${MASC_LINUX_ARCH:-x64}"
if [[ "${ARCH}" == "x64" ]]; then PLATFORM="linux/amd64"; else PLATFORM="linux/arm64"; fi

mkdir -p "${DIST_DIR}"
if ! gh release download "v${MASC_VERSION}" -R jeong-sik/masc \
     -p "masc-linux-${ARCH}" -O "${DIST_DIR}/masc" --clobber; then
  echo "no masc-linux-${ARCH} asset on v${MASC_VERSION}. Releases that exist:" >&2
  gh release list -R jeong-sik/masc --limit 5 >&2 || true
  exit 1
fi
# The remote_ssh exec lane invokes `masc-exec-shim` on the remote PATH; the
# release ships it as a separate static binary (note: the x64 asset is amd64).
SHIM_ARCH="${ARCH}"; [[ "${ARCH}" == "x64" ]] && SHIM_ARCH="amd64"
gh release download "v${MASC_VERSION}" -R jeong-sik/masc \
  -p "masc-exec-shim-linux-${SHIM_ARCH}" -O "${DIST_DIR}/masc-exec-shim" --clobber
chmod +x "${DIST_DIR}/masc" "${DIST_DIR}/masc-exec-shim"
printf '%s\n' "$MASC_VERSION" > "${DIST_DIR}/.version"

# gh is required on the remote PATH by the keeper_up preflight (`gh auth
# status`) and is absent from debian stable, which most Terminal-Bench python
# base images use. Ship it in dist/ so bootstrap.sh never has to find a
# package for it.
GH_VERSION="${GH_VERSION:-2.65.0}"
GH_ARCH="${ARCH}"; [[ "${ARCH}" == "x64" ]] && GH_ARCH="amd64"
curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${GH_ARCH}.tar.gz" \
  | tar -xz -C "${DIST_DIR}" --strip-components=2 "gh_${GH_VERSION}_linux_${GH_ARCH}/bin/gh"
chmod +x "${DIST_DIR}/gh"


# Record what was downloaded. A release asset can be replaced or truncated,
# and nothing else here would notice.
( cd "${DIST_DIR}" && shasum -a 256 masc masc-exec-shim gh 2>/dev/null > SHA256SUMS ) || true

# Verify by running it, and let that verdict stand. The old form was
#   bash -c 'masc --version || masc --help | head -5'
# whose inner shell inherits no errexit and ends in `head`, so it exits 0 for a
# truncated download, a wrong-arch asset, or a binary missing every library —
# while its comment claimed to verify the binary runs.
docker run --rm --platform "${PLATFORM}" \
  -v "${DIST_DIR}:/opt/dist:ro" \
  ubuntu:24.04 /opt/dist/masc --version
