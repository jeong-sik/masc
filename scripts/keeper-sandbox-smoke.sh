#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image_tag="${MASC_KEEPER_SANDBOX_DOCKER_IMAGE:-masc-keeper-sandbox:local}"

"$repo_root/scripts/build-keeper-sandbox-image.sh" "$image_tag"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

playground="$tmpdir/playground"
mkdir -p "$playground"
printf 'alpha\nbeta\ngamma\n' > "$playground/demo.txt"

docker run --rm \
  --read-only \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=64m \
  --cap-drop=ALL \
  --security-opt no-new-privileges \
  --network none \
  -v "$playground:/workspace:rw" \
  --workdir /workspace \
  "$image_tag" \
  bash -lc '
    set -euo pipefail
    for cmd in sh bash git gh rg tree jq python3 node npm make opam dune; do
      command -v "$cmd" >/dev/null
    done
    test "$(cat demo.txt)" = $'"'"'alpha\nbeta\ngamma'"'"'
    rg beta demo.txt >/dev/null
    printf "delta\n" >> append.txt
    test "$(cat append.txt)" = "delta"
  '

container_name="keeper-sandbox-smoke-$$"
docker run -d --rm \
  --name "$container_name" \
  --read-only \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=64m \
  --cap-drop=ALL \
  --security-opt no-new-privileges \
  --network none \
  -v "$playground:/workspace:rw" \
  --workdir /workspace \
  "$image_tag" \
  sh -lc 'trap : TERM INT; while :; do sleep 3600; done' >/dev/null

trap 'docker rm -f "$container_name" >/dev/null 2>&1 || true; rm -rf "$tmpdir"' EXIT

docker exec "$container_name" bash -lc 'cat demo.txt >/tmp/readback && test -s /tmp/readback'
docker exec "$container_name" bash -lc 'printf "zeta\n" > exec-write.txt'
docker exec "$container_name" bash -lc 'rg gamma demo.txt >/dev/null'
docker rm -f "$container_name" >/dev/null

test "$(cat "$playground/exec-write.txt")" = "zeta"
printf 'keeper sandbox smoke passed for %s\n' "$image_tag"
