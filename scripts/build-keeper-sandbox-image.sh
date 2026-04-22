#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image_tag="${1:-${MASC_KEEPER_SANDBOX_DOCKER_IMAGE:-masc-keeper-sandbox:local}}"

cd "$repo_root"
docker build -f Dockerfile.keeper-sandbox -t "$image_tag" .
