#!/usr/bin/env bash
# build-linux-release.sh — build the Linux release binaries at a declared glibc floor.
#
# Why this exists
# ---------------
# The release workflow builds the Linux binaries directly on its runner, so
# the oldest glibc they run against is whatever that runner image ships. On
# ubuntu-24.04 (glibc 2.39) the result needed GLIBC_2.38 for two symbols the
# code never asks for, `fmod` and `__isoc23_strtol`, and therefore refused to
# start on Debian 12, on Ubuntu 22.04, and on 26 of Terminal-Bench 4.0's 66
# task images (masc#35321).
#
# Patching those two symbols would fix those two symbols. The next compiler or
# runner-image bump adds different ones, silently, and nothing fails until a
# user on an older distro reports a linker error. So the floor is set by the
# build environment instead: build inside a container whose glibc *is* the
# floor, and there is nothing newer to reference.
#
# This follows the exec shim's precedent (scripts/remote-ssh/build-shim.sh):
# a release artifact whose target environment differs from the runner's is
# built in a container, on the runner's own architecture, with no emulation.
#
# Why Ubuntu 22.04 (glibc 2.35)
# -----------------------------
# It covers 64 of Terminal-Bench 4.0's 66 images and every currently supported
# Debian and Ubuntu. Debian 11 (glibc 2.31) would add one more image, but
# bullseye is end-of-life: its security repository's Release file has expired
# and apt refuses it. A release toolchain does not sit on a distro nobody
# patches, so 2.35 is the floor.
#
# Usage:
#   scripts/build-linux-release.sh [--out DIR] [--floor 2.35] [--image IMG]
#                                  [--jobs N] [--keep] [--print-binaries]
#
#   --out DIR          where to place the built binaries
#                      (default: <repo>/artifacts/linux-<arch>)
#   --floor VERSION    glibc floor to enforce (default: 2.35)
#   --image IMAGE      builder image (default: ocaml/opam:ubuntu-22.04-ocaml-5.5)
#   --jobs N           dune -j (default: container default)
#   --keep             leave the build container running for inspection
#   --print-binaries   list the binaries this script produces, then exit
#
# The build runs natively for the host architecture. Cross-building via qemu
# is not offered: the release workflow gives each architecture its own runner,
# and an emulated OCaml build is slow enough to be its own failure mode.
#
# The container gets the repo's *tracked* files only (`git ls-files`), so an
# untracked local file cannot change what a release contains.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The binaries release.yml packages for Linux. The exec shim is not here: it
# is a static musl binary with its own builder (scripts/remote-ssh/build-shim.sh)
# and no glibc floor to meet.
release_binaries=(
  bin/main_eio.exe
  bin/masc_tui.exe
  bin/masc_browser_host.exe
  bin/deployment_preflight_helper.exe
)

# Built and exported alongside the release binaries, but not shipped, so the
# glibc floor does not apply to them: they run on the release runner itself.
# They are built here so that the Linux job needs no second OCaml toolchain —
# with these exported, nothing on the runner has to invoke dune at all.
support_binaries=(
  test/test_tool_contract_truth.exe
)

# Pinned rather than "latest": ubuntu 22.04 ships protoc 3.12, which rejects
# this repo's protos ("proto3 optional fields, but
# --experimental_allow_proto3_optional was not set"). The runner image happened
# to carry a new enough copy, which is why the workflow never installed one.
protoc_version=25.1

out_dir=""
floor=2.35
image="ocaml/opam:ubuntu-22.04-ocaml-5.5"
jobs=""
keep=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out) out_dir="${2:?--out needs a directory}"; shift 2 ;;
    --floor) floor="${2:?--floor needs a version}"; shift 2 ;;
    --image) image="${2:?--image needs an image}"; shift 2 ;;
    --jobs) jobs="${2:?--jobs needs a number}"; shift 2 ;;
    --keep) keep=1; shift ;;
    --print-binaries)
      for binary in "${release_binaries[@]}" "${support_binaries[@]}"; do
        printf '%s\n' "$(basename "$binary")"
      done
      exit 0
      ;;
    -h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "build-linux-release: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  echo "build-linux-release: docker is required" >&2
  exit 2
fi

host_arch="$(uname -m)"
case "$host_arch" in
  x86_64) arch_label=x64; protoc_arch=x86_64 ;;
  aarch64|arm64) arch_label=arm64; protoc_arch=aarch_64 ;;
  *) echo "build-linux-release: unsupported host architecture '$host_arch'" >&2; exit 2 ;;
esac

out_dir="${out_dir:-$repo_root/artifacts/linux-$arch_label}"
container="masc-linux-release-build-$$"

cleanup() {
  if [ "$keep" -eq 1 ]; then
    echo "== container kept as $container (docker rm -f $container to remove)"
    return
  fi
  docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== builder image $image"
docker pull "$image"
docker run --rm "$image" bash -lc 'ldd --version | head -1; ocaml -version'

docker rm -f "$container" >/dev/null 2>&1 || true
docker run -d --name "$container" "$image" sleep infinity >/dev/null

echo "== system dependencies"
docker exec -u root "$container" bash -c '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    pkg-config m4 git curl ca-certificates unzip binutils python3 \
    libgmp-dev libssl-dev libzstd-dev libsqlite3-dev libpq-dev \
    libev-dev libffi-dev zlib1g-dev
'

echo "== protoc $protoc_version"
docker exec -u root "$container" bash -c "
  set -e
  curl -fsSL -o /tmp/protoc.zip \
    'https://github.com/protocolbuffers/protobuf/releases/download/v${protoc_version}/protoc-${protoc_version}-linux-${protoc_arch}.zip'
  unzip -q -o /tmp/protoc.zip -d /usr/local
  chmod +x /usr/local/bin/protoc
  rm -f /tmp/protoc.zip
  protoc --version
"

echo "== copy tracked sources"
tracked="$(mktemp)"
trap 'rm -f "$tracked"; cleanup' EXIT
git -C "$repo_root" ls-files -z > "$tracked"
tar -C "$repo_root" --null -T "$tracked" -cf - \
  | docker exec -i -u root "$container" bash -c \
      'mkdir -p /src && tar -C /src -xf - && chown -R opam:opam /src'

# The repo supports exactly OCaml 5.5.1; the image's default switch is not
# guaranteed to be that patch release.
echo "== opam switch 5.5.1"
docker exec "$container" bash -lc '
  set -e
  opam switch list-available ocaml-base-compiler | grep -q 5.5.1 || opam update -y
  opam switch create masc 5.5.1 -y
'

echo "== pin private dependencies"
docker exec "$container" bash -lc '
  set -e
  cd /src
  eval "$(opam env --switch=masc)"
  bash scripts/opam-pin-external-deps.sh --with-compact-protocol --with-bisect
'

# --with-test, matching release.yml. The support binaries below are test
# executables and need the test dependency set; --with-bisect on the pin step
# above exists so that this stays solvable on OCaml 5.5.
echo "== opam install --deps-only --with-test"
docker exec "$container" bash -lc '
  set -e
  cd /src
  eval "$(opam env --switch=masc)"
  for attempt in 1 2 3; do
    opam install . --deps-only --with-test -y && break
    if [ "$attempt" -eq 3 ]; then echo "opam install failed after 3 attempts" >&2; exit 1; fi
    echo "opam install failed (attempt $attempt); retrying in 15s"
    sleep 15
  done
'

# Bake SQLite into the executables rather than requiring libsqlite3.so.0 on
# the target host: libsqlite3-dev ships the static archive, and removing the
# shared linker symlink makes -lsqlite3 resolve to it.
#
# The order matters and is release.yml's. Removing the symlink before `opam
# install` instead makes the OCaml sqlite3 package fail to build, because its
# stub *shared* library cannot link a non-PIC static archive
# ("relocation ... can not be used when making a shared object"). The symlink
# has to survive until the bindings are built and disappear before the
# executables are linked.
echo "== prefer static SQLite"
docker exec -u root "$container" bash -c 'rm -f /usr/lib/*/libsqlite3.so /usr/lib/libsqlite3.so'

# Built on the host side rather than passed through the environment: DUNE_JOBS
# is dune's own variable and it rejects an empty value outright.
jobs_flag=""
if [ -n "$jobs" ]; then
  jobs_flag="-j $jobs"
fi

echo "== build"
docker exec "$container" bash -lc '
  set -e
  cd /src
  eval "$(opam env --switch=masc)"
  dune build --release '"${release_binaries[*]} ${support_binaries[*]} $jobs_flag"'
'

built_paths=()
for binary in "${release_binaries[@]}"; do
  built_paths+=("/src/_build/default/$binary")
done

echo "== glibc floor $floor"
docker exec "$container" bash -lc '
  cd /src
  bash scripts/check-glibc-floor.sh '"$floor ${built_paths[*]}"'
'

# The self-contained claim, asserted the same way release.yml asserts it.
echo "== no dynamic SQLite"
docker exec "$container" bash -lc '
  set -e
  for path in '"${built_paths[*]}"'; do
    if ldd "$path" 2>/dev/null | grep -qi sqlite; then
      echo "$path still dynamically links sqlite3:" >&2
      ldd "$path" | grep -i sqlite >&2
      exit 1
    fi
  done
  echo "no binary carries a dynamic sqlite dependency"
'

echo "== collect into $out_dir"
mkdir -p "$out_dir"
for binary in "${release_binaries[@]}" "${support_binaries[@]}"; do
  name="$(basename "$binary")"
  docker cp "$container:/src/_build/default/$binary" "$out_dir/$name"
  chmod +x "$out_dir/$name"
done

echo
echo "built at glibc floor $floor for linux-$arch_label:"
for binary in "${release_binaries[@]}" "${support_binaries[@]}"; do
  name="$(basename "$binary")"
  printf '  %s (%s bytes)\n' "$out_dir/$name" "$(wc -c < "$out_dir/$name" | tr -d ' ')"
done
