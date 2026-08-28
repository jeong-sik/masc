#!/usr/bin/env bash
# Build an ephemeral SSH endpoint and run the gated Phase 1 integration test.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$repo_root/test/fixtures/sshd"
shim_artifact="$repo_root/artifacts/masc-exec-shim"
# macOS OpenSSH rejects ControlPath sockets at 104 bytes. Keep this fixture
# root intentionally short so the test exercises the configured [%C] path,
# not a host-temp-directory artifact.
fixture_stage="$(mktemp -d /tmp/masc-ssh-fixture.XXXXXX)"
container_name="masc-ssh-fixture-$$"
image_tag="masc-ssh-fixture:$$"

cleanup() {
  docker rm -f "$container_name" >/dev/null 2>&1 || true
  docker image rm "$image_tag" >/dev/null 2>&1 || true
  rm -rf "$fixture_stage"
}
trap cleanup EXIT INT TERM

if ! command -v docker >/dev/null 2>&1 || ! docker version >/dev/null 2>&1; then
  echo "test-ssh-fixture: Docker is required" >&2
  exit 1
fi

shim_stale=false
if [[ ! -x "$shim_artifact" ]]; then
  shim_stale=true
else
  for source in \
    "$repo_root/lib/exec_ssh_protocol/exec_ssh_protocol.ml" \
    "$repo_root/lib/exec_shim/exec_shim.ml" \
    "$repo_root/lib/exec_shim/prctl_stub.c" \
    "$repo_root/bin/masc_exec_shim.ml"; do
    if [[ "$source" -nt "$shim_artifact" ]]; then
      shim_stale=true
      break
    fi
  done
fi

if [[ "$shim_stale" == true ]]; then
  "$repo_root/scripts/build-shim-static.sh" "$shim_artifact"
fi

ssh-keygen -q -t ed25519 -N "" -C "masc-ssh-fixture" \
  -f "$fixture_stage/id_ed25519"
chmod 0600 "$fixture_stage/id_ed25519"
cp "$fixture_stage/id_ed25519.pub" "$fixture_stage/fixture.pub"
cp "$shim_artifact" "$fixture_stage/masc-exec-shim"
cp "$fixture_root/Dockerfile" "$fixture_stage/Dockerfile"
cp "$fixture_root/entrypoint.sh" "$fixture_stage/entrypoint.sh"

docker build --quiet --tag "$image_tag" "$fixture_stage" >/dev/null
docker run --detach --rm --name "$container_name" \
  --publish 127.0.0.1::22 "$image_tag" >/dev/null

port="$(docker inspect --format '{{(index (index .NetworkSettings.Ports "22/tcp") 0).HostPort}}' "$container_name")"
known_hosts="$fixture_stage/known_hosts"

ready=false
for _attempt in $(seq 1 50); do
  if ssh-keyscan -T 1 -p "$port" -t ed25519 127.0.0.1 >"$known_hosts" 2>/dev/null \
     && [[ -s "$known_hosts" ]]; then
    ready=true
    break
  fi
  sleep 0.1
done
if [[ "$ready" != true ]]; then
  echo "test-ssh-fixture: sshd did not publish a host key" >&2
  docker logs "$container_name" >&2 || true
  exit 1
fi
chmod 0600 "$known_hosts"

ssh -T -F none \
  -o BatchMode=yes \
  -o IdentitiesOnly=yes \
  -i "$fixture_stage/id_ed25519" \
  -o StrictHostKeyChecking=yes \
  -o "UserKnownHostsFile=$known_hosts" \
  -p "$port" masc@127.0.0.1 true

fixture_value="127.0.0.1:$port:$fixture_stage"
echo "MASC_TEST_SSH_FIXTURE=$fixture_value"

if [[ "${1:-}" == "--print-and-wait" ]]; then
  echo "export MASC_TEST_SSH_FIXTURE='$fixture_value'"
  echo "Fixture is running; press Ctrl-C to stop."
  while true; do sleep 60; done
fi

if [[ $# -gt 0 ]]; then
  MASC_TEST_SSH_FIXTURE="$fixture_value" "$@"
else
  cd "$repo_root"
  scripts/dune-local.sh build test/test_keeper_ssh_integration.exe
  MASC_TEST_SSH_FIXTURE="$fixture_value" \
    _build/default/test/test_keeper_ssh_integration.exe
fi
