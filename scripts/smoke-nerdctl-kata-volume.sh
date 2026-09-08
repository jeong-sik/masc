#!/usr/bin/env bash
# Opt-in real Linux Kata persistence/isolation proof; requires an existing image.
# Usage: scripts/smoke-nerdctl-kata-volume.sh [masc-sandbox:general]
set -euo pipefail
image="${1:-masc-sandbox:general}"
[ "$(uname -s)" = Linux ] || { echo 'Linux host required' >&2; exit 1; }
command -v nerdctl >/dev/null
command -v python3 >/dev/null
nerdctl image inspect "$image" >/dev/null
proof_name="masc-volume-proof-$(date +%s)-$$"
volume="$proof_name-work"
cleanup() {
  nerdctl rm -f "$proof_name" >/dev/null 2>&1 || true
  nerdctl volume rm "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT
nerdctl volume create "$volume"
nerdctl volume inspect "$volume"
# Root creates the keeper-owned directory once; no SYS_ADMIN or writable rootfs.
nerdctl run --rm --runtime io.containerd.kata.v2 --network none \
  --read-only --cap-drop ALL --tmpfs /tmp --pull never \
  -v "$volume:/masc-work" "$image" mkdir -m 0777 /masc-work/keeper
for phase in write read; do
  nerdctl run -d --name "$proof_name" --runtime io.containerd.kata.v2 \
    --network none --read-only --cap-drop ALL --tmpfs /tmp --pull never \
    --user 60123:60123 -v "$volume:/masc-work" \
    -w /masc-work/keeper "$image" tail -f /dev/null
  # Native inspection embeds containerd core/containers.Container.Runtime.Name.
  # https://github.com/containerd/nerdctl/blob/v2.3.5/pkg/inspecttypes/native/container.go
  nerdctl inspect --mode native "$proof_name" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
assert len(rows) == 1 and rows[0]["Runtime"]["Name"] == "io.containerd.kata.v2", rows
print(json.dumps(rows, indent=2))
'
  # Root owns /: a failed non-root touch would only prove Unix permissions.
  nerdctl exec --user 0:0 "$proof_name" sh -ec '
    test "$(id -u)" = 0
    if touch /masc-rootfs-proof 2>/dev/null; then exit 1; fi
  '
  nerdctl exec --user 60123:60123 "$proof_name" sh -ec '
    grep -qF " /masc-work " /proc/mounts
    test "$(id -u)" = 60123
    grep -q "^CapEff:[[:space:]]*0000000000000000$" /proc/self/status
    touch /tmp/scratch-proof
  '
  if [ "$phase" = write ]; then
    nerdctl exec --user 60123:60123 "$proof_name" sh -ec \
      'printf "persistent keeper data\n" > /masc-work/keeper/proof'
  else
    nerdctl exec --user 60123:60123 "$proof_name" sh -ec \
      'test "$(cat /masc-work/keeper/proof)" = "persistent keeper data"'
  fi
  nerdctl rm -f "$proof_name"
done
echo 'PASS: Kata managed volume survives guest recreation; uid, caps, rootfs and scratch checks passed'
