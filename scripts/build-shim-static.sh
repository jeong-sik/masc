#!/usr/bin/env bash
# build-shim-static.sh — build a statically linked Linux masc-exec-shim.
#
# The shim ships to remote Linux hosts as a single static ELF
# (docs/superpowers/specs/2026-08-27-openssh-microvm-exec-design.md §4.2).
# Host (macOS) builds of bin/masc_exec_shim.exe stay dynamic; this script
# produces the Linux artifact on demand inside an ocaml/opam:alpine
# container (musl → true static linking without glibc's NSS caveats).
#
# Usage:
#   scripts/build-shim-static.sh [output-path]
#     default output: <repo>/artifacts/masc-exec-shim
#
# Env overrides:
#   SHIM_BUILD_IMAGE     container image (default: ocaml/opam:alpine-3.24-ocaml-5.5,
#                        matching the repo switch's OCaml 5.5).  Pinned by
#                        tag, NOT digest — once the produced artifact is
#                        confirmed good in the Task 10 fixture, digest-pinning
#                        the image is a deliberate follow-up.
#   SHIM_BUILD_PLATFORM  docker --platform (default: native; use
#                        linux/amd64 to cross-build x86_64 from arm64 via
#                        qemu — slow but works)
#
# Portability note: the /out bind-mount relies on Docker Desktop's
# ownership mapping (files created by the container's unprivileged opam
# user land writable on the macOS host).  On a Linux docker host the
# container uid may not match the host user — adjust the artifact copy
# (e.g. docker --user $(id -u)) there.
#
# The script vendors ONLY the shim's own sources (lib/exec_ssh_protocol,
# lib/exec_shim, bin/masc_exec_shim.ml) into a scratch dune project, so the
# container never needs the full masc dependency set: dune + yojson +
# base64 only, pinned to the repo switch's versions.  The committed dune
# files are never modified; the static link flag (-ccopt -static) exists
# only in the scratch project's dune file.
#
# After the build, `file` must confirm a fully static ELF — modern
# musl/gcc toolchains report `-static` output as "static-pie linked"
# (still no interpreter, no shared libs), older ones as "statically
# linked" — or the script fails.  The artifact is exercised end-to-end by
# the Task 10 integration fixture and provisioned by the Task 9 bootstrap.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_path="${1:-"$repo_root/artifacts/masc-exec-shim"}"
image="${SHIM_BUILD_IMAGE:-ocaml/opam:alpine-3.24-ocaml-5.5}"

# Dep versions pinned to the repo opam switch.
dune_version=3.24.1
yojson_version=3.0.0
base64_version=3.5.2

if ! command -v docker >/dev/null 2>&1; then
  echo "build-shim-static: docker is not installed or not on PATH" >&2
  exit 1
fi
if ! docker version >/dev/null 2>&1; then
  echo "build-shim-static: docker daemon is not reachable" >&2
  exit 1
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/src" "$stage/out"

cp "$repo_root/lib/exec_ssh_protocol/exec_ssh_protocol.ml" \
   "$repo_root/lib/exec_ssh_protocol/exec_ssh_protocol.mli" \
   "$repo_root/lib/exec_shim/exec_shim.ml" \
   "$repo_root/lib/exec_shim/exec_shim.mli" \
   "$repo_root/lib/exec_shim/prctl_stub.c" \
   "$repo_root/lib/exec_shim/observe_stub.c" \
   "$repo_root/bin/masc_exec_shim.ml" \
   "$stage/src/"

cat > "$stage/src/dune-project" <<'EOF'
(lang dune 3.0)
EOF

cat > "$stage/src/dune" <<'EOF'
(library
 (name exec_ssh_protocol)
 (modules exec_ssh_protocol)
 (libraries yojson base64))

(library
 (name exec_shim)
 (modules exec_shim)
 (libraries exec_ssh_protocol unix)
 (foreign_stubs
  (language c)
  (names prctl_stub observe_stub)))

(executable
 (name masc_exec_shim)
 (modules masc_exec_shim)
 (libraries exec_shim)
 (link_flags -ccopt -static))
EOF

platform_args=()
if [ -n "${SHIM_BUILD_PLATFORM:-}" ]; then
  platform_args=(--platform "$SHIM_BUILD_PLATFORM")
fi

# ${platform_args[@]+...} guard: bash 3.2 (macOS /bin/bash) treats
# "${empty_array[@]}" as unbound under set -u.
docker run --rm ${platform_args[@]+"${platform_args[@]}"} \
  -v "$stage/src:/src:ro" \
  -v "$stage/out:/out" \
  "$image" sh -euxc "
    command -v gcc >/dev/null 2>&1 || apk add --no-cache build-base
    opam install -y dune.$dune_version yojson.$yojson_version base64.$base64_version
    eval \$(opam env)
    # The image runs as the unprivileged opam user; / is not writable.
    cp -r /src \"\$HOME/work\"
    cd \"\$HOME/work\"
    dune build ./masc_exec_shim.exe
    cp _build/default/masc_exec_shim.exe /out/masc-exec-shim
    strip /out/masc-exec-shim 2>/dev/null || true
  "

file_out="$(file "$stage/out/masc-exec-shim")"
echo "build-shim-static: $file_out"
case "$file_out" in
  *"statically linked"* | *"static-pie linked"*)
    case "$file_out" in
      *"dynamically linked"* | *"interpreter"*)
        echo "build-shim-static: FAIL — artifact has a dynamic interpreter" >&2
        exit 1 ;;
    esac ;;
  *)
    echo "build-shim-static: FAIL — artifact is not a statically linked ELF" >&2
    exit 1 ;;
esac

mkdir -p "$(dirname "$out_path")"
cp "$stage/out/masc-exec-shim" "$out_path"
chmod +x "$out_path"
echo "build-shim-static: wrote $out_path"
