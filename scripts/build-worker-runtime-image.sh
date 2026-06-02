#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
git_sha="$(git -C "$repo_root" rev-parse --short HEAD)"
image_tag="${1:-masc-worker-runtime:local-${git_sha}}"

echo "Building ${image_tag}"
docker build -f "${repo_root}/Dockerfile.worker-runtime" -t "${image_tag}" "${repo_root}"
