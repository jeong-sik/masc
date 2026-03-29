#!/usr/bin/env bash
# Pin private/external opam dependencies that are not published on opam-repository.
#
# NOTE: Most first-party packages here intentionally float on #main. OAS does
# not float at install time, and mcp_protocol is pinned to the current released
# single-package line so local setup does not drift across packaging changes.
# OAS itself is ratcheted to the current upstream main commit in one shared
# place so CI/runtime stay reproducible while still consuming the latest
# required OAS feature set. Set AGENT_SDK_PIN_URL to a local checkout/worktree
# path when validating unreleased OAS changes locally. If you need reproducible
# builds for the remaining dependencies, pin them to specific commit SHAs
# instead:
#   opam pin add <pkg> <url>#<commit-sha> -n -y
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/oas-agent-sdk-pin.sh"

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
opam pin add ocaml-webrtc https://github.com/jeong-sik/ocaml-webrtc.git#main -n -y
opam pin add grpc-direct-core https://github.com/jeong-sik/grpc-direct.git#main -n -y
opam pin add grpc-direct https://github.com/jeong-sik/grpc-direct.git#main -n -y
opam pin add neo4j_packstream https://github.com/jeong-sik/ocaml-neo4j-bolt.git#main -n -y
opam pin add neo4j_bolt_common https://github.com/jeong-sik/ocaml-neo4j-bolt.git#main -n -y
opam pin add neo4j_bolt https://github.com/jeong-sik/ocaml-neo4j-bolt.git#main -n -y
opam pin add neo4j_bolt_eio https://github.com/jeong-sik/ocaml-neo4j-bolt.git#main -n -y

if $include_bisect; then
  # bisect_ppx opam constraints lag newer compilers; keep CI solvable under OCaml 5.4 by pinning.
  opam pin add bisect_ppx git+https://github.com/patricoferris/bisect_ppx.git#5.2 -n -y
fi
