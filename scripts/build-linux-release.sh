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
#   --run-contract-test  also run test/test_tool_contract_truth.exe in the
#                      container (release.yml asks for this on one arch)
#   --lifecycle-out DIR run the full lifecycle matrix in the builder and export
#                      its source-bound bundle and logs for host verification
#   --print-binaries   list the binaries this script produces, then exit
#   --print-floor      print the glibc floor this script builds at, then exit
#                      (release.yml re-checks the packaged assets at it, so the
#                      workflow reads the value here instead of repeating it)
#
# The build runs natively for the host architecture. Cross-building via qemu
# is not offered: the release workflow gives each architecture its own runner,
# and an emulated OCaml build is slow enough to be its own failure mode.
#
# The container gets the repo's *tracked* files only (`git ls-files`), so an
# untracked local file cannot change what a release contains. Content comes
# from the working tree, so local edits to tracked files are built; a brand
# new file has to be `git add`ed before this script can see it.
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

# Run inside the container with --run-contract-test, not exported and run on
# the host. The test resolves its workspace through the environment dune sets
# up for `dune exec`, so the bare executable run from a checkout answers
# "MASC_BASE_PATH is not set" and exits 1. Keeping it where the toolchain is
# keeps it running exactly as it did before this script existed.
contract_test=test/test_tool_contract_truth.exe

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
run_contract_test=0
lifecycle_out=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --lifecycle-out) lifecycle_out="${2:?--lifecycle-out needs a directory}"; shift 2 ;;
    --out) out_dir="${2:?--out needs a directory}"; shift 2 ;;
    --floor) floor="${2:?--floor needs a version}"; shift 2 ;;
    --image) image="${2:?--image needs an image}"; shift 2 ;;
    --jobs) jobs="${2:?--jobs needs a number}"; shift 2 ;;
    --keep) keep=1; shift ;;
    --run-contract-test) run_contract_test=1; shift ;;
    --print-binaries)
      for binary in "${release_binaries[@]}"; do
        printf '%s\n' "$(basename "$binary")"
      done
      exit 0
      ;;
    --print-floor) printf '%s\n' "$floor"; exit 0 ;;
    -h|--help) sed -n '2,55p' "${BASH_SOURCE[0]}"; exit 0 ;;
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

# Only tracked files are copied into the container, so /src has no .git and the
# probe in lib/build_commit/ finds no checkout to ask. Left alone it embeds
# None, `masc build-commit` then exits 1, and scripts/release-dashboard-bundle.py
# refuses to package a binary that cannot name its own commit -- the "binary
# unknown" state RFC-0382 set out to end. The checkout's HEAD is read here and
# handed to that probe through the environment; the build step below verifies
# the binaries came out carrying it.
build_commit="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
if [ -z "$build_commit" ]; then
  echo "build-linux-release: no git HEAD here; release binaries must carry a commit" >&2
  exit 2
fi
build_commit_unix_ts="$(git -C "$repo_root" show -s --format=%ct "$build_commit" 2>/dev/null || true)"

# Content comes from the working tree (see the header), so an edited checkout
# produces binaries that name a commit they were not built from. CI cannot
# reach this -- release.yml runs `git diff --exit-code` before packaging -- but
# a local build can, and it should say so rather than ship a quiet lie.
if ! git -C "$repo_root" diff --quiet HEAD -- 2>/dev/null; then
  echo "build-linux-release: tracked files differ from HEAD; the binaries will still claim $build_commit" >&2
fi

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

# libncurses-dev and libprotobuf-dev are here for the opam solve, not for the
# link. conf-ncurses runs `pkg-config ncurses`, which needs the .pc file that
# only libncurses-dev carries, and its depext name for Ubuntu is
# "lib64ncurses-dev" -- not a package here, so opam cannot repair the miss on
# its own. Dockerfile.keeper-sandbox records the same solve failing that way
# (exit 20 out of the opam stage, measured 2026-08-26). conf-protoc lists
# libprotobuf-dev and protobuf-compiler as its depexts; naming them keeps the
# apt run here instead of somewhere inside `opam install`.
echo "== system dependencies"
docker exec -u root "$container" bash -c '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    pkg-config m4 git curl ca-certificates unzip binutils python3 \
    libgmp-dev libssl-dev libzstd-dev libsqlite3-dev libpq-dev \
    libev-dev libffi-dev zlib1g-dev libncurses-dev \
    libprotobuf-dev protobuf-compiler
'

echo "== protoc $protoc_version"
docker exec -u root "$container" bash -c "
  set -e
  curl -fsSL -o /tmp/protoc.zip \
    'https://github.com/protocolbuffers/protobuf/releases/download/v${protoc_version}/protoc-${protoc_version}-linux-${protoc_arch}.zip'
  unzip -q -o /tmp/protoc.zip -d /usr/local
  chmod +x /usr/local/bin/protoc
  rm -f /tmp/protoc.zip
  # apt just put 22.04's protoc 3.12 in /usr/bin as one of conf-protoc's
  # depexts. /usr/local/bin comes first on PATH, so the pinned copy is what
  # dune runs -- asserted rather than assumed, because the 3.12 failure is a
  # proto parse error far from here.
  protoc --version
  protoc --version | grep -q '${protoc_version}\$'
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
echo "== opam install --deps-only --with-test --locked"
docker exec "$container" bash -lc '
  set -e
  cd /src
  eval "$(opam env --switch=masc)"
  for attempt in 1 2 3; do
    opam install . --deps-only --with-test --locked -y && break
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
docker exec \
  -e MASC_BUILD_COMMIT="$build_commit" \
  -e MASC_BUILD_COMMIT_UNIX_TS="$build_commit_unix_ts" \
  "$container" bash -lc '
  set -e
  cd /src
  eval "$(opam env --switch=masc)"
  dune build --release '"${release_binaries[*]} $jobs_flag"'
'

# The injection above is only as good as what came out. A binary that cannot
# name its commit fails two jobs later, in packaging, where the cause is far
# from the cure.
echo "== embedded build commit"
docker exec -e MASC_BUILD_COMMIT="$build_commit" "$container" bash -lc '
  set -e
  embedded="$(/src/_build/default/bin/main_eio.exe build-commit)"
  if [ "$embedded" != "$MASC_BUILD_COMMIT" ]; then
    printf "build-linux-release: binary reports commit %s, expected %s\n" \
      "${embedded:-<none>}" "$MASC_BUILD_COMMIT" >&2
    exit 1
  fi
  printf "binaries testify to %s\n" "$embedded"
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

if [ "$run_contract_test" -eq 1 ]; then
  echo "== tool contract truth"
  docker exec "$container" bash -lc '
    set -e
    cd /src
    eval "$(opam env --switch=masc)"
    dune exec --release '"$contract_test"'
  '
fi

echo "== collect into $out_dir"
mkdir -p "$out_dir"
for binary in "${release_binaries[@]}"; do
  name="$(basename "$binary")"
  docker cp "$container:/src/_build/default/$binary" "$out_dir/$name"
  chmod +x "$out_dir/$name"
done

# The checked release binaries have already been exported. Dune lifecycle
# aliases may rebuild their dependencies in the dev profile; those bytes must
# never replace the release-profile artifacts checked above.
# The host deliberately has no OCaml toolchain. Run the unchanged lifecycle
# matrix where its native dependencies live, then verify its exported logs
# against the checked-out commit before the host installation smoke uses them.
if [ -n "$lifecycle_out" ]; then
  lifecycle_status=0
  docker exec -e MASC_BUILD_COMMIT="$build_commit" \
    -e MASC_BUILD_COMMIT_UNIX_TS="$build_commit_unix_ts" "$container" bash -lc '
    set -e
    cd /src
    eval "$(opam env --switch=masc)"
    python3 scripts/keeper-full-lifecycle-evidence.py \
      --build-source-sha "$MASC_BUILD_COMMIT" --output-dir /tmp/masc-release-lifecycle
  ' || lifecycle_status=$?
  mkdir -p "$lifecycle_out"
  docker cp "$container:/tmp/masc-release-lifecycle/." "$lifecycle_out/"
  if [ "$lifecycle_status" -ne 0 ]; then
    exit "$lifecycle_status"
  fi
  python3 "$repo_root/scripts/keeper-full-lifecycle-evidence.py" \
    --verify --output-dir "$lifecycle_out"
fi


echo
echo "built at glibc floor $floor for linux-$arch_label:"
for binary in "${release_binaries[@]}"; do
  name="$(basename "$binary")"
  printf '  %s (%s bytes)\n' "$out_dir/$name" "$(wc -c < "$out_dir/$name" | tr -d ' ')"
done
