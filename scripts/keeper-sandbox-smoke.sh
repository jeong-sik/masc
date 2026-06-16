#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image_tag="${MASC_KEEPER_SANDBOX_DOCKER_IMAGE:-masc-keeper-sandbox:local}"

"$repo_root/scripts/build-keeper-sandbox-image.sh" "$image_tag"

# Keep the bind-mounted smoke workspace under the repo by default. On macOS,
# plain `mktemp -d` can land under /var/folders, which Colima does not expose
# to Docker bind mounts even when /Users is mounted.
tmp_parent="${MASC_KEEPER_SANDBOX_SMOKE_TMPDIR:-$repo_root/.tmp}"
mkdir -p "$tmp_parent"
tmpdir="$(mktemp -d "$tmp_parent/keeper-sandbox-smoke.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

playground="$tmpdir/playground"
mkdir -p "$playground"
printf 'alpha\nbeta\ngamma\n' > "$playground/demo.txt"
cat > "$playground/dune-project" <<'EOF'
(lang dune 3.22)
(name keeper_sandbox_probe)
EOF
cat > "$playground/dune" <<'EOF'
(executable
 (name probe)
 (libraries agent_sdk agent_sdk.llm_provider))
EOF
cat > "$playground/probe.ml" <<'EOF'
let () = ()
EOF

# Extract required dune version from dune-project: (lang dune X.Y)
req_dune_ver="$(grep -E '^\(lang dune\b' "$repo_root/dune-project" \
                | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"

docker run --rm -i \
  --read-only \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=64m \
  --cap-drop=ALL \
  --security-opt no-new-privileges \
  --network none \
  -e "MASC_REQ_DUNE_VER=$req_dune_ver" \
  -v "$playground:/workspace:rw" \
  --workdir /workspace \
  "$image_tag" \
  bash -l -s <<'BASH'
    set -euo pipefail
    for cmd in sh bash git gh rg tree jq python3 node npm make opam dune ocamlfind; do
      command -v "$cmd" >/dev/null
    done
    # Verify sandbox dune version meets dune-project requirement (Fix C: sandbox launch invariant)
    actual_dune="$(dune --version)"
    if ! printf "%s\n%s\n" "$MASC_REQ_DUNE_VER" "$actual_dune" | sort -V -C; then
      printf "FAIL: sandbox dune %s < dune-project requires %s\n" "$actual_dune" "$MASC_REQ_DUNE_VER" >&2
      exit 1
    fi
    printf "OK: sandbox dune %s >= required %s\n" "$actual_dune" "$MASC_REQ_DUNE_VER"
    ocamlfind query agent_sdk >/dev/null
    ocamlfind query agent_sdk.llm_provider >/dev/null
    dune build ./probe.exe
    test "$(cat demo.txt)" = $'alpha\nbeta\ngamma'
    rg beta demo.txt >/dev/null
    printf "delta\n" >> append.txt
    test "$(cat append.txt)" = "delta"
BASH

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
  tail -f /dev/null >/dev/null

trap 'docker rm -f "$container_name" >/dev/null 2>&1 || true; rm -rf "$tmpdir"' EXIT

printf '%s\n' 'cat demo.txt >/tmp/readback && test -s /tmp/readback' |
  docker exec -i "$container_name" bash -l -s
printf '%s\n' 'printf "zeta\n" > exec-write.txt' |
  docker exec -i "$container_name" bash -l -s
printf '%s\n' 'rg gamma demo.txt >/dev/null' |
  docker exec -i "$container_name" bash -l -s
docker rm -f "$container_name" >/dev/null

test "$(cat "$playground/exec-write.txt")" = "zeta"
printf 'keeper sandbox smoke passed for %s\n' "$image_tag"
