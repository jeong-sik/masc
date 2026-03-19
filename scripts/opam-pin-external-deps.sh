#!/usr/bin/env bash
# Pin private/external opam dependencies that are not published on opam-repository.
#
# NOTE: These pins use branch refs (#main) intentionally. These are private
# first-party packages where we control both sides. Version constraints for
# compatibility are declared in masc_mcp.opam (e.g., mcp_protocol >= 0.13.0).
# If you need reproducible builds, pin to a specific commit SHA instead:
#   opam pin add <pkg> <url>#<commit-sha> -n -y
set -euo pipefail

include_bisect=false
include_compact_protocol=false

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

opam pin add mcp_protocol https://github.com/jeong-sik/mcp-protocol-sdk.git#main -n -y
opam pin add mcp_protocol_eio https://github.com/jeong-sik/mcp-protocol-sdk.git#main -n -y
opam pin add mcp_protocol_http https://github.com/jeong-sik/mcp-protocol-sdk.git#main -n -y
opam pin add agent_sdk https://github.com/jeong-sik/oas.git#main -n -y
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
