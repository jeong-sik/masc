#!/usr/bin/env bash
# Download the pinned prebuilt masc server binary and verify it runs in a
# linux container of the target architecture. No local build (constitution).
set -euo pipefail

MASC_VERSION="${MASC_VERSION:-0.35.8}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/../dist"
ARCH="${MASC_LINUX_ARCH:-arm64}"   # Apple Silicon docker → arm64; Intel/amd64 호스트면 x64
if [[ "${ARCH}" == "x64" ]]; then PLATFORM="linux/amd64"; else PLATFORM="linux/arm64"; fi

mkdir -p "${DIST_DIR}"
gh release download "v${MASC_VERSION}" -R jeong-sik/masc \
  -p "masc-linux-${ARCH}" -O "${DIST_DIR}/masc" --clobber
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


docker run --rm --platform "${PLATFORM}" \
  -v "${DIST_DIR}:/opt/dist:ro" \
  ubuntu:24.04 bash -c '/opt/dist/masc --version || /opt/dist/masc --help | head -5'
