#!/usr/bin/env bash
# Generate gRPC reflection descriptors from proto sources.
# Outputs base64-encoded FileDescriptorProto for each proto file.
#
# Usage:
#   scripts/gen-grpc-descriptors.sh          # print to stdout
#   scripts/gen-grpc-descriptors.sh --check  # verify current OCaml matches generated\n#   scripts/gen-grpc-descriptors.sh --write  # rewrite the OCaml in place
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

# Rewrite the descriptor in place.  Without this the only way to apply a proto
# change was to copy the generated base64 out of stdout by hand, which is how
# #30344 shipped a proto whose descriptor still described the old wire schema.
do_write() {
  check_protoc
  local b64
  b64="$(gen_descriptor_b64 "masc_workspace.proto")"
  python3 - "${TARGET_ML}" "${b64}" <<'PY'
import sys

path, b64 = sys.argv[1], sys.argv[2]
lines = open(path).read().split("\n")
start = next(i for i, l in enumerate(lines) if "let grpc_masc_descriptor_b64 =" in l)
concat = next(i for i in range(start, start + 5) if "String.concat" in lines[i])
end = next(i for i in range(concat + 1, len(lines)) if lines[i].strip() == "]")
chunks = [b64[i : i + 100] for i in range(0, len(b64), 100)]
block = [("      [ " if n == 0 else "      ; ") + '"' + c + '"' for n, c in enumerate(chunks)]
block.append("      ]")
lines[concat + 1 : end + 1] = block
open(path, "w").write("\n".join(lines))
print("wrote %d chunks (%d bytes) to %s" % (len(chunks), len(b64), path))
PY
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
    echo "Regenerate with: scripts/gen-grpc-descriptors.sh --write" >&2
    exit 1
  fi
}

case "${1:-}" in
  --check) do_check ;;
  --write) do_write ;;
  --help|-h) echo "Usage: $0 [--check|--write]" ;;
  *) do_generate ;;
esac
