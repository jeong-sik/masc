#!/usr/bin/env bash
set -euo pipefail

# Build the masc-worker-runtime Docker image.
# Usage: scripts/build-worker-image.sh [TAG]
#   TAG defaults to "dev".

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:-dev}"
IMAGE="masc-worker-runtime:${TAG}"

echo "Building ${IMAGE} from ${REPO_ROOT}/Dockerfile.worker"
docker build \
  -f "${REPO_ROOT}/Dockerfile.worker" \
  -t "${IMAGE}" \
  "${REPO_ROOT}"

echo "Built ${IMAGE}"
echo "Verify: echo '{}' | docker run --rm -i ${IMAGE}"
