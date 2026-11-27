#!/usr/bin/env bash
# build-shim.sh
#
# Build masc-exec-shim as a statically linked Linux binary for one or both
# architectures. Static musl linking (Alpine toolchain) removes the glibc
# version dependency, so the same binary runs on any Linux distribution a
# vendor hands out (Debian, Ubuntu, Amazon Linux, RHEL, Alpine, ...).
#
# The build runs inside ocaml/opam containers; nothing is installed on the
# host. The first run per architecture installs the shim's dune/yojson/base64/uuidm
# closure into the container and caches it by architecture, base image,
# compiler, dependency manifest and builder recipe so matching runs skip the opam step.
#
# Usage:
#   scripts/remote-ssh/build-shim.sh [--arch amd64|arm64|all] [--out DIR] [--notices]
#   scripts/remote-ssh/build-shim.sh --arch amd64|arm64 --print-builder-config
#     Print tag/compiler key-value lines without Docker or filesystem writes.
#
# Output:
#   <out>/masc-exec-shim-linux-<arch>   (default out: dist/remote-ssh)
#   A sha256 line per binary, and a hard failure if the result is not
#   statically linked.
#   With --notices, also <out>/masc-exec-shim-licenses-linux-<arch>.tar.gz:
#   the license notices of what the binary links (masc#39934), the release
#   asset scripts/package-exec-shim-notices.py describes. The release build
#   asks for it; it needs network access, and a refused collection fails the
#   build.
set -euo pipefail

ARCHES="amd64 arm64"
OUT_DIR="dist/remote-ssh"
PRINT_BUILDER_CONFIG=false
NOTICES=false

while [ $# -gt 0 ]; do
  case "$1" in
    --print-builder-config)
      PRINT_BUILDER_CONFIG=true
      ;;
    --notices)
      NOTICES=true
      ;;
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
compiler_version="$(sed -n 's/^  (ocaml (= \([0-9.]*\)))$/\1/p' "$repo_root/dune-project")"
case "$compiler_version" in
  '' | *[!0-9.]*) echo "build-shim: expected one exact OCaml version in dune-project" >&2; exit 1 ;;
esac
# Local builds and Actions use the same recipe and compiler identity. Source
# changes rebuild the shim, but do not invalidate its prepared toolchain.
builder_recipe="$repo_root/scripts/remote-ssh/Dockerfile.shim-builder"
recipe_hash="$(shasum -a 256 "$builder_recipe" | cut -d ' ' -f 1)"
dependency_hash="$(shasum -a 256 "$repo_root/dune-project" | cut -d ' ' -f 1)"
builder_key="$(printf '%s\n' "$compiler_version" "$recipe_hash" "$dependency_hash" | shasum -a 256 | cut -d ' ' -f 1)"

if [ "$PRINT_BUILDER_CONFIG" = true ]; then
  case "$ARCHES" in
    amd64|arm64) ;;
    *) echo "--print-builder-config requires one --arch" >&2; exit 2 ;;
  esac
  printf 'tag=masc-shim-build:%s-%s\ncompiler=%s\ndependency_hash=%s\n' "$ARCHES" "$builder_key" "$compiler_version" "$dependency_hash"
  exit 0
fi

# RFC host-and-shim-share-one-build-identity. The shim declares the source
# identity lib/build_commit/probe-commit.sh computes, and a server runs only a
# shim whose identity equals its own. Inside the container the dune rule sees
# no checkout (the build directory is outside /src), so the same probe runs
# here on the checkout and its values go in through the environment the rule
# falls back to. A checkout with no identity builds no shim.
identity_env="$(cd "$repo_root" && sh lib/build_commit/probe-commit.sh --print-env)"
identity_args=()
while IFS= read -r assignment; do
  identity_args+=(-e "$assignment")
done <<<"$identity_env"

mkdir -p "$repo_root/$OUT_DIR"
# The unprivileged image user must be able to write to the Linux bind mount.
chmod a+rwx "$repo_root/$OUT_DIR"

prepare_builder() {
  arch="$1"
  tag="masc-shim-build:$arch-$builder_key"
  if docker image inspect "$tag" >/dev/null 2>&1; then
    return 0
  fi
  echo "[build-shim] preparing $tag" >&2
  docker build --platform "linux/$arch" --tag "$tag" \
    --build-arg "OCAML_COMPILER=$compiler_version" \
    --build-arg "SHIM_DEPENDENCY_HASH=$dependency_hash" - < "$builder_recipe"
}

build_one() {
  arch="$1"
  out="$repo_root/$OUT_DIR/masc-exec-shim-linux-$arch"
  # A new binary leaves an earlier notice archive describing other bytes.
  rm -f "$repo_root/$OUT_DIR/masc-exec-shim-licenses-linux-$arch.tar.gz"
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
    "${identity_args[@]}" \
    "$tag" \
    sh -lc 'cd /tmp && opam exec --switch=masc-shim -- dune build --root /src --build-dir /tmp/shimbuild bin/masc_exec_shim.exe \
      && install -m 755 /tmp/shimbuild/default/bin/masc_exec_shim.exe /out/masc-exec-shim-linux-'"$arch"''
  # Non-PIE static reports exactly "statically linked". A dynamic binary
  # would resurrect the glibc-version dependency this script exists to
  # remove, and static-pie is rejected on purpose (see the link flags above).
  if ! grep -q "statically linked" <<<"$(file "$out")"; then
    echo "[build-shim] $out is not statically linked:" >&2
    file "$out" >&2
    exit 1
  fi
  shasum -a 256 "$out"
}

# --notices (masc#39934): the notices are read in the builder that linked the
# shim, from its opam switch and its musl, the way
# scripts/build-linux-release.sh reads the runtime's in its own builder.
# scripts/collect-ocaml-notices.py reads dune's release-profile link rule after
# a release build of the same target, so that build runs here in a build
# directory of its own; the shim installed above is not rebuilt. OPAMSWITCH
# points the collector's own opam calls at the switch that linked the shim.
collect_notices() {
  arch="$1"
  echo "[build-shim] collecting the $arch license notices" >&2
  docker run --rm --platform "linux/$arch" \
    -v "$repo_root:/src:ro" \
    -v "$repo_root/$OUT_DIR:/out" \
    -e OCAMLPARAM="_,ccopt=-static,ccopt=-no-pie" \
    -e DUNE_BUILD_DIR=/tmp/shimnotices \
    -e OPAMSWITCH=masc-shim \
    -e SHIM_ARCH="$arch" \
    "${identity_args[@]}" \
    "$tag" \
    sh -lc 'set -e
      cd /src
      opam exec -- dune build --release bin/masc_exec_shim.exe
      opam exec -- python3 scripts/collect-ocaml-notices.py --out /tmp/shim-ocaml-notices bin/masc_exec_shim.exe
      python3 scripts/package-exec-shim-notices.py package --arch "$SHIM_ARCH" \
        --shim "/out/masc-exec-shim-linux-$SHIM_ARCH" --ocaml-notices /tmp/shim-ocaml-notices \
        --output "/out/masc-exec-shim-licenses-linux-$SHIM_ARCH.tar.gz"'
}

for arch in $ARCHES; do
  build_one "$arch"
  if [ "$NOTICES" = true ]; then
    collect_notices "$arch"
  fi
done
