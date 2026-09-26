#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image_tag="${1:-masc-keeper-sandbox:local}"

cd "$repo_root"
docker build -f sandbox-images/ocaml/Dockerfile -t "$image_tag" .
