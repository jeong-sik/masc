#!/usr/bin/env bash
# build-shim.sh
#
# Build masc-exec-shim as a statically linked Linux binary for one or both
# architectures. Static musl linking (Alpine toolchain) removes the glibc
# version dependency, so the same binary runs on any Linux distribution a
# vendor hands out (Debian, Ubuntu, Amazon Linux, RHEL, Alpine, ...).
#
# The build runs inside ocaml/opam containers; nothing is installed on the
# host. The first run per architecture installs the shim's dune/yojson/base64
# closure into the container and commits it as masc-shim-build:<arch> so later
# runs skip the opam step.
#
# Usage:
#   scripts/remote-ssh/build-shim.sh [--arch amd64|arm64|all] [--out DIR]
#
# Output:
#   <out>/masc-exec-shim-linux-<arch>   (default out: dist/remote-ssh)
#   A sha256 line per binary, and a hard failure if the result is not
#   statically linked.
set -euo pipefail

BASE_IMAGE="ocaml/opam:alpine-3.24-ocaml-5.5"
ARCHES="amd64 arm64"
OUT_DIR="dist/remote-ssh"
prep_container=""

cleanup_prep_container() {
  [ -z "$prep_container" ] \
    || docker rm -f "$prep_container" >/dev/null 2>&1 \
    || true
}
trap cleanup_prep_container EXIT INT TERM

while [ $# -gt 0 ]; do
  case "$1" in
    --arch)
      shift
      case "${1:-}" in
        amd64 | arm64) ARCHES="$1" ;;
        all) ARCHES="amd64 arm64" ;;
        *)
          echo "unknown --arch value: ${1:-}" >&2
          exit 2
          ;;
      esac
      ;;
    --out)
      shift
      OUT_DIR="${1:?--out needs a directory}"
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

repo_root="$(git rev-parse --show-toplevel)"
mkdir -p "$repo_root/$OUT_DIR"
# The build container installs the result into the bind-mounted output
# directory as its own user (opam, uid 1000). On a Linux host the mount keeps
# the host's ownership, so a directory the invoking user owns refuses that
# write (GitHub's ubuntu runners: "install: cannot create regular file
# '/out/...': Permission denied"). Docker Desktop and Apple's container map
# the write to the host user, so this is a no-op there.
chmod a+rwx "$repo_root/$OUT_DIR"

prepare_builder() {
  arch="$1"
  tag="masc-shim-build:$arch"
  if docker image inspect "$tag" >/dev/null 2>&1; then
    return 0
  fi
  echo "[build-shim] preparing $tag (first run per arch: opam install)" >&2
  prep_container="masc-shim-prep-$arch-$$"
  docker run --platform "linux/$arch" --name "$prep_container" "$BASE_IMAGE" \
    sh -lc 'opam install -y dune yojson base64 >/dev/null'
  docker commit "$prep_container" "$tag" >/dev/null
  docker rm "$prep_container" >/dev/null
  prep_container=""
}

build_one() {
  arch="$1"
  out="$repo_root/$OUT_DIR/masc-exec-shim-linux-$arch"
  prepare_builder "$arch"
  echo "[build-shim] building $arch" >&2
  # OCAMLPARAM ccopt makes the final link fully static on musl; the repo's
  # dune files stay untouched and macOS builds are unaffected. -no-pie picks
  # the classic non-PIE static form: Alpine's default static-pie segfaults
  # under x86_64 emulation (Docker on Apple Silicon), and the non-PIE form
  # runs everywhere we can test.
  docker run --rm --platform "linux/$arch" \
    -v "$repo_root:/src:ro" \
    -v "$repo_root/$OUT_DIR:/out" \
    -e OCAMLPARAM="_,ccopt=-static,ccopt=-no-pie" \
    "masc-shim-build:$arch" \
    sh -lc 'cd /tmp && dune build --root /src --build-dir /tmp/shimbuild bin/masc_exec_shim.exe \
      && install -m 755 /tmp/shimbuild/default/bin/masc_exec_shim.exe /out/masc-exec-shim-linux-'"$arch"''
  # Non-PIE static reports exactly "statically linked". A dynamic binary
  # would resurrect the glibc-version dependency this script exists to
  # remove, and static-pie is rejected on purpose (see the link flags above).
  if ! file "$out" | grep -q "statically linked"; then
    echo "[build-shim] $out is not statically linked:" >&2
    file "$out" >&2
    exit 1
  fi
  shasum -a 256 "$out"
}

for arch in $ARCHES; do
  build_one "$arch"
done
