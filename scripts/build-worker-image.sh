#!/usr/bin/env bash
set -euo pipefail

# Compatibility wrapper for building the local masc-worker-runtime image.
# Usage: scripts/build-worker-image.sh [TAG]
#   TAG defaults to "dev".

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:-dev}"
IMAGE="masc-worker-runtime:${TAG}"

exec "${REPO_ROOT}/scripts/build-worker-runtime-image.sh" "${IMAGE}"
