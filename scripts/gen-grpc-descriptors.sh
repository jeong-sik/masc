#!/usr/bin/env bash
# Generate gRPC reflection descriptors from proto sources.
# Outputs base64-encoded FileDescriptorProto for each proto file.
#
# Usage:
#   scripts/gen-grpc-descriptors.sh          # print to stdout
#   scripts/gen-grpc-descriptors.sh --check  # verify current OCaml matches generated
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROTO_DIR="${REPO_ROOT}/proto"
TARGET_ML="${REPO_ROOT}/lib/server/masc_grpc_server.ml"

check_protoc() {
  if ! command -v protoc &>/dev/null; then
    echo "error: protoc not found. Install with: brew install protobuf" >&2
    exit 1
  fi
}

gen_descriptor_b64() {
  local proto_file="$1"
  local tmp_bin tmp_raw
  tmp_bin="$(mktemp)"
  tmp_raw="$(mktemp)"
  trap "rm -f '${tmp_bin}' '${tmp_raw}'" RETURN
  protoc \
    --descriptor_set_out="${tmp_bin}" \
    --proto_path="${PROTO_DIR}" \
    "${proto_file}"
  # protoc --descriptor_set_out produces a FileDescriptorSet wrapper.
  # Strip the outer wrapper to get raw FileDescriptorProto.
  # FileDescriptorSet = tag(0x0a) + varint(length) + FileDescriptorProto
  python3 -c "
import sys
data = open('${tmp_bin}', 'rb').read()
# Skip tag byte (0x0a = field 1, wire type 2)
i = 1
# Skip varint length
while data[i] & 0x80:
    i += 1
i += 1
sys.stdout.buffer.write(data[i:])
" > "${tmp_raw}"
  base64 < "${tmp_raw}" | tr -d '\n'
}

do_generate() {
  check_protoc
  echo "--- masc_workspace.proto ---"
  gen_descriptor_b64 "masc_workspace.proto"
  echo ""
  echo ""
  echo "--- grpc_health_v1.proto ---"
  gen_descriptor_b64 "grpc_health_v1.proto"
  echo ""
}

do_check() {
  check_protoc
  local masc_gen
  masc_gen="$(gen_descriptor_b64 "masc_workspace.proto")"

  # Extract current masc descriptor from OCaml source.
  # The descriptor is split across multiple lines with ^ concatenation.
  local masc_current
  masc_current="$(
    sed -n '/let grpc_masc_descriptor_b64 =/,/^$/p' "${TARGET_ML}" \
      | grep -oE '"[A-Za-z0-9+/=]+"' \
      | tr -d '"' \
      | tr -d '\n'
  )"

  if [ "${masc_gen}" = "${masc_current}" ]; then
    echo "OK: masc_workspace collaboration descriptor matches proto source."
    exit 0
  else
    echo "DRIFT: masc_workspace collaboration descriptor does not match proto source." >&2
    echo "" >&2
    echo "Generated (first 80 chars): ${masc_gen:0:80}..." >&2
    echo "Current   (first 80 chars): ${masc_current:0:80}..." >&2
    echo "" >&2
    echo "Regenerate with: scripts/gen-grpc-descriptors.sh" >&2
    exit 1
  fi
}

case "${1:-}" in
  --check) do_check ;;
  --help|-h) echo "Usage: $0 [--check]" ;;
  *) do_generate ;;
esac
