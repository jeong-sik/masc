---
rfc: "0100"
title: "Current MCP HTTP transport"
status: Active
created: 2026-05-17
updated: 2026-08-04
author: vincent
supersedes: []
superseded_by: null
related: ["0098", "0099"]
implementation_prs: [26775]
---

# RFC-0100 — Current MCP HTTP transport

**Status:** Active

**Surface:** `POST /mcp`

**Protocol revision:** `2026-07-28`

## Contract

Every MCP request is independently authenticated and self-describing. The server
does not require a protocol handshake or connection-scoped protocol state.

Required request headers:

- `Content-Type: application/json`
- `Accept: application/json, text/event-stream`
- `Mcp-Protocol-Version: 2026-07-28`
- `Mcp-Method: <JSON-RPC method>`
- `Mcp-Name: <name-or-uri>` for methods whose target is named

The JSON-RPC `params._meta` object mirrors the protocol revision and client
capabilities:

```json
{
  "io.modelcontextprotocol/protocolVersion": "2026-07-28",
  "io.modelcontextprotocol/clientCapabilities": {}
}
```

The header and body revision must match. Missing, mismatched, and unsupported
revisions are typed request errors. Successful result objects carry an explicit
`resultType`; completed calls use `"complete"`.

## Response delivery

Normal calls return JSON. A call that produces incremental output may use SSE on
the same POST response when the request accepts `text/event-stream`. Framing does
not change authentication or request semantics.

MASC observer feeds are separate read surfaces. They use bearer authentication
and require an explicit stable observer identifier in the `session_id` query
parameter; they are not part of the MCP request protocol.

## Ownership

- `Mcp_transport_protocol` owns the supported revision and metadata keys.
- `Server_mcp_transport_http_headers` owns header/body agreement.
- `Server_mcp_request_context` owns request admission.
- `Server_mcp_transport_http` and `Server_h2_gateway` share the same admission
  result and response contract.
- `scripts/harness/lib/mcp_jsonrpc.sh` is the shell-client request builder SSOT.

## Verification

- `test/test_mcp_protocol_coverage.ml`
- `test/test_http_negotiation.ml`
- `test/test_mcp_h1_h2_admission_parity.ml`
- `test/test_mcp_post_sse_e2e.ml`
- `scripts/harness/contract/streamable_http_contract.sh`
