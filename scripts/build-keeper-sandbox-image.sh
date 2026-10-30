#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image_tag="${1:-masc-keeper-sandbox:local}"

cd "$repo_root"
if command -v sha256sum >/dev/null 2>&1; then
  lock_sha256=$(sha256sum masc.opam.locked | awk '{print $1}')
else
  lock_sha256=$(shasum -a 256 masc.opam.locked | awk '{print $1}')
fi
docker build --label "masc.sandbox.opam_lock_sha256=$lock_sha256" \
  -f sandbox-images/ocaml/Dockerfile -t "$image_tag" .
