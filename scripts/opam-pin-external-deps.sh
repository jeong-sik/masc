#!/usr/bin/env bash
# Pin private/external opam dependencies that are not published on opam-repository.
#
# All first-party packages are pinned to specific commit SHAs so that the
# opam cache in CI stays stable across runs. When upstream changes are needed,
# bump the SHA constants below and in oas-agent-sdk-pin.sh.
#
# To bump a pin:
#   git ls-remote https://github.com/jeong-sik/<repo>.git HEAD
#   # update the readonly SHA below, commit, push
#
# For local development against an unreleased checkout:
#   AGENT_SDK_PIN_URL=/path/to/local/oas opam-pin-external-deps.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/oas-agent-sdk-pin.sh"

# --- Pin SHAs (bump these when upstream changes are needed) ---
readonly WEBRTC_SHA="1b7993605b293f45169369d488f970ba15132a9f"
readonly GRPC_DIRECT_SHA="840b6cd6fe822d3577aa26147e7dc71ca25abecc"
readonly NEO4J_BOLT_SHA="a1ca30c1247db5c58934e99306fe330419f7b21a"

include_bisect=false
include_compact_protocol=false
agent_sdk_pin_source="${AGENT_SDK_PIN_URL:-${OAS_AGENT_SDK_URL}#${OAS_AGENT_SDK_SHA}}"

for arg in "$@"; do
  case "$arg" in
    --with-bisect)
      include_bisect=true
      ;;
    --with-compact-protocol)
      include_compact_protocol=true
      ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

if $include_compact_protocol; then
  opam pin add compact-protocol https://github.com/jeong-sik/compact-protocol.git#main -n -y
fi

# mcp_protocol_eio and mcp_protocol_http merged into mcp_protocol
# as sub-libraries (mcp-protocol-sdk#60). Pin the released single-package line.
opam pin add mcp_protocol https://github.com/jeong-sik/mcp-protocol-sdk.git#v1.3.0 -n -y
opam pin add agent_sdk "${agent_sdk_pin_source}" -n -y
opam pin add ocaml-webrtc "https://github.com/jeong-sik/ocaml-webrtc.git#${WEBRTC_SHA}" -n -y
opam pin add grpc-direct-core "https://github.com/jeong-sik/grpc-direct.git#${GRPC_DIRECT_SHA}" -n -y
opam pin add grpc-direct "https://github.com/jeong-sik/grpc-direct.git#${GRPC_DIRECT_SHA}" -n -y
opam pin add neo4j_packstream "https://github.com/jeong-sik/ocaml-neo4j-bolt.git#${NEO4J_BOLT_SHA}" -n -y
opam pin add neo4j_bolt_common "https://github.com/jeong-sik/ocaml-neo4j-bolt.git#${NEO4J_BOLT_SHA}" -n -y
opam pin add neo4j_bolt "https://github.com/jeong-sik/ocaml-neo4j-bolt.git#${NEO4J_BOLT_SHA}" -n -y
opam pin add neo4j_bolt_eio "https://github.com/jeong-sik/ocaml-neo4j-bolt.git#${NEO4J_BOLT_SHA}" -n -y

if $include_bisect; then
  # bisect_ppx opam constraints lag newer compilers; keep CI solvable under OCaml 5.4 by pinning.
  opam pin add bisect_ppx git+https://github.com/patricoferris/bisect_ppx.git#5.2 -n -y
fi
