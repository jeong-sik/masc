#!/usr/bin/env bash
# Opt-in real Linux Kata persistence/isolation proof; requires an existing image.
# Usage: scripts/smoke-nerdctl-kata-volume.sh [masc-sandbox:general]
set -euo pipefail
image="${1:-masc-sandbox:general}"
[ "$(uname -s)" = Linux ] || { echo 'Linux host required' >&2; exit 1; }
command -v nerdctl >/dev/null
command -v python3 >/dev/null
# nerdctl 2.3.5 dockercompat inspect normalizes the requested empty tag to
# "latest" but leaves a digest-only candidate tag empty, rejecting an image
# just pulled by digest. Native inspect returns the containerd image record.
# https://github.com/containerd/nerdctl/blob/v2.3.5/pkg/cmd/image/inspect.go#L109-L134
# Native mode can return an empty list successfully, so confirm the record and
# the requested immutable digest explicitly instead of trusting exit status.
nerdctl image inspect --mode native "$image" | python3 -c '
import json, sys
requested = sys.argv[1]
rows = json.load(sys.stdin)
assert isinstance(rows, list) and rows, "native image inspection returned no image"
images = [row["Image"] for row in rows]
if "@" in requested:
    name, digest = requested.rsplit("@", 1)
    matches = [image for image in images if image["Name"] == requested and image["Target"]["digest"] == digest]
    assert len(matches) == 1, "native image name/digest differs from the requested pin"
    images = matches
print(json.dumps([{"name": image["Name"], "target": image["Target"]["digest"]} for image in images]))
' "$image"
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
  -v "$volume:/masc-work" "$image" sh -ec '
    grep -qF " /masc-work " /proc/mounts
    stat -c "before: %a %u:%g %n" /masc-work
    chmod a+x /masc-work
    mkdir -m 0777 /masc-work/keeper
    stat -c "prepared: %a %u:%g %n" /masc-work /masc-work/keeper
  '
for phase in write read; do
  nerdctl run -d --name "$proof_name" --runtime io.containerd.kata.v2 \
    --label "masc.mcp.keeper=$proof_name" --label masc.mcp.component=keeper-sandbox \
    --label masc.mcp.kind=keeper-vm --label "masc.mcp.owner_pid=$$" \
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
  # Exercise the production inventory template against the real Kata guest.
  # This validates nerdctl output fields; it does not invoke MASC's sweep or
  # claim installed Keeper acceptance. An ordinary --format json omits LabelsMap.
  nerdctl ps -a --no-trunc --format '{"id":{{json .ID}},"name":{{json .Names}},"image":{{json .Image}},"status":{{json .Status}},"created_at":{{json .CreatedAt}},"runtime":{{json .Runtime}},"labels":{{json .LabelsMap}}}' \
    | python3 -c '
import json, sys
name, owner = sys.argv[1:]
rows = [json.loads(line) for line in sys.stdin if line.strip()]
matches = [row for row in rows if row["name"] == name]
assert len(matches) == 1, "Kata guest absent or duplicated in native template listing"
row = matches[0]
assert len(row["id"]) == 64 and all(c in "0123456789abcdef" for c in row["id"]), row
assert row["runtime"] == "io.containerd.kata.v2", row
assert row["labels"]["masc.mcp.keeper"] == name, row
assert row["labels"]["masc.mcp.owner_pid"] == owner, row
assert row["labels"]["masc.mcp.component"] == "keeper-sandbox", row
assert row["labels"]["masc.mcp.kind"] == "keeper-vm", row
assert all(isinstance(row[key], str) for key in ["name", "image", "status", "created_at"]), row
print("KATA_LABELLED_INVENTORY " + json.dumps(row, sort_keys=True))
' "$proof_name" "$$"
  # Root owns /: a failed non-root touch would only prove Unix permissions.
  nerdctl exec --user 0:0 "$proof_name" sh -ec '
    test "$(id -u)" = 0
    if touch /masc-rootfs-proof 2>/dev/null; then exit 1; fi
  '
  nerdctl exec --user 60123:60123 "$proof_name" sh -ec '
    stat -c "guest: %a %u:%g %n" /masc-work /masc-work/keeper
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
