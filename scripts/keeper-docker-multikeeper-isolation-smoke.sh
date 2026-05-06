#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image_tag="${MASC_KEEPER_SANDBOX_DOCKER_IMAGE:-masc-keeper-sandbox:local}"

if ! docker image inspect "$image_tag" >/dev/null 2>&1; then
  "$repo_root/scripts/build-keeper-sandbox-image.sh" "$image_tag"
fi

security_options="$(docker info --format '{{json .SecurityOptions}}' 2>/dev/null || true)"
if [[ "${MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS:-false}" == "true" ]] \
  && ! grep -qi 'rootless' <<<"$security_options"; then
  printf 'FAIL: Docker rootless mode required but not reported by docker info\n' >&2
  exit 1
fi
if [[ "${MASC_KEEPER_SANDBOX_REQUIRE_USERNS:-false}" == "true" ]] \
  && ! grep -qi 'userns' <<<"$security_options"; then
  printf 'FAIL: Docker userns support required but not reported by docker info\n' >&2
  exit 1
fi
if ! grep -qi 'rootless' <<<"$security_options"; then
  printf 'WARN: Docker rootless mode not reported; continuing because it is not required\n' >&2
fi
if ! grep -qi 'userns' <<<"$security_options"; then
  printf 'WARN: Docker userns support not reported; continuing because it is not required\n' >&2
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/playgrounds/keeper-a" "$tmpdir/playgrounds/keeper-b"
mkdir -p "$tmpdir/creds/keeper-a/gh" "$tmpdir/creds/keeper-b/gh"
printf 'keeper-a-playground\n' > "$tmpdir/playgrounds/keeper-a/own.txt"
printf 'keeper-b-playground\n' > "$tmpdir/playgrounds/keeper-b/own.txt"
printf 'keeper-a-gh\n' > "$tmpdir/creds/keeper-a/gh/identity.txt"
printf 'keeper-b-gh\n' > "$tmpdir/creds/keeper-b/gh/identity.txt"
printf 'keeper-a-gh-only\n' > "$tmpdir/creds/keeper-a/gh/keeper-a.txt"
printf 'keeper-b-gh-only\n' > "$tmpdir/creds/keeper-b/gh/keeper-b.txt"

run_keeper() {
  local keeper="$1"
  local other="$2"
  local playground="$tmpdir/playgrounds/$keeper"
  local gh_dir="$tmpdir/creds/$keeper/gh"
  local expected="$keeper-gh"
  local expected_playground="$keeper-playground"

  docker run --rm -i \
    --label masc.keeper.sandbox=true \
    --label "masc.keeper.id=$keeper" \
    --user "$(id -u):$(id -g)" \
    --read-only \
    --tmpfs /tmp:rw,nosuid,nodev,noexec,size=64m \
    --cap-drop=ALL \
    --security-opt no-new-privileges \
    --network none \
    -v "$playground:/workspace:rw" \
    -v "$gh_dir:/tmp/keeper-creds/.config/gh:ro" \
    --workdir /workspace \
    -e "EXPECTED_IDENTITY=$expected" \
    -e "EXPECTED_PLAYGROUND=$expected_playground" \
    -e "OTHER_KEEPER=$other" \
    "$image_tag" \
    bash -lc '
      set -euo pipefail
      test "$(cat own.txt)" = "$EXPECTED_PLAYGROUND"
      test ! -e "/workspace/$OTHER_KEEPER"
      test "$(cat /tmp/keeper-creds/.config/gh/identity.txt)" = "$EXPECTED_IDENTITY"
      test -e "/tmp/keeper-creds/.config/gh/${EXPECTED_IDENTITY%-gh}.txt"
      test ! -e "/tmp/keeper-creds/.config/gh/${OTHER_KEEPER}.txt"
      if (printf probe >/tmp/keeper-creds/.config/gh/write-probe) 2>/dev/null; then
        printf "credential projection is writable\n" >&2
        exit 21
      fi
      printf "ok\n" > write-ok.txt
    ' >/dev/null

  test "$(cat "$playground/write-ok.txt")" = "ok"
}

run_keeper keeper-a keeper-b
run_keeper keeper-b keeper-a

printf 'keeper docker multi-keeper isolation smoke passed for %s\n' "$image_tag"
