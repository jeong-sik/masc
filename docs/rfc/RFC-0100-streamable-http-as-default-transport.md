---
rfc: "0100"
title: "Streamable HTTP as default transport (MCP 2025-03-26)"
status: Draft
created: 2026-05-17
updated: 2026-05-17
author: vincent
supersedes: []
superseded_by: null
related: ["0098", "0099"]
implementation_prs: []
---

# RFC-0100 — Streamable HTTP as default transport (MCP 2025-03-26)

Status: Draft
Author: jeong-sik (vincent)
Date: 2026-05-17
Scope: HTTP transport surface (`POST /mcp`) — chunked-first default, auto-upgrade to SSE on demand, `Mcp-Session-Id` header, legacy `GET /sse` deprecation window
Out of scope: provider-side streaming wire-up ([[RFC-0095]], merged), error envelope shape ([[RFC-0098]]), session lifecycle events ([[RFC-0099]] — *consumed* by this RFC for resume/eviction), FD accounting (IMPROVE-03), TTFT measurement ([[RFC-OAS-020]] in oas)
Series: **IMPROVE-02** of the masc-mcp + oas improvement series.

## 1. Problem

MCP spec 2025-03-26 deprecates the legacy HTTP+SSE transport pair and introduces **Streamable HTTP**: a single chunked HTTP response that optionally upgrades to SSE when the server has a long-running response to deliver. masc-mcp's current HTTP transport is the *legacy* pair:

- `POST /mcp` — synchronous JSON response (blocking until full body ready)
- `GET /sse?sse_kind=...&session_id=...` — long-lived SSE channel for events

Three concrete defects of the legacy shape:

### 1.1 Streaming is opt-in via separate endpoint

Clients must know to open a separate `GET /sse` for streaming events. MCP 2025-03-26 clients (and the new Anthropic / OpenAI client SDKs) instead expect `POST /mcp` to be either synchronous *or* chunked depending on the server's processing time — one URL, one connection.

### 1.2 Session keying via query string

Current SSE uses `?sse_kind=observer&session_id=...` query parameters. The new spec keys session via the **`Mcp-Session-Id` HTTP header** (returned by server on `Open`, echoed by client thereafter). Query-string keying:
- Leaks session IDs in proxy access logs.
- Is incompatible with stateless load balancers that route by header.
- Forces session migration to be a re-handshake instead of a header re-send.

### 1.3 ALB / Cloudflare drop long-lived SSE GET connections

Production tests observed 20/22 SSE GET connections dropped within 60 s when fronted by typical L7 middleboxes that don't honor SSE keepalive comments at idle. Streamable HTTP's chunked response with an active first chunk within ~50 ms keeps middleboxes from declaring the request idle.

## 2. Non-goals

- **Replacing [[RFC-0095]]'s provider-side streaming.** RFC-0095 is about `Custom_openai_compat` emitting chunks *into* masc-mcp. This RFC is about masc-mcp emitting chunks *out to* clients. Orthogonal layers.
- **Changing [[RFC-0098]]'s error envelope shape.** Codes, message, data field — all unchanged. This RFC affects the *delivery shape* (chunked vs synchronous), not the body.
- **Implementing session-lifecycle event publishing.** [[RFC-0099]] owns that. This RFC's `Mcp-Session-Id` header is the *carrier*; the lifecycle events live on RFC-0099's bus.
- **Implementing Last-Event-ID resume.** [[RFC-0099]] PR-6 owns the resume machinery. This RFC defines *that the header is honored*; the ring-buffer / replay implementation is RFC-0099's.
- **Removing legacy `GET /sse` immediately.** External agent clients still depend on it. 6-month deprecation window (§4.4).
- **WS / gRPC / WebRTC transport changes.** This RFC is HTTP-specific.

## 3. Design

### 3.1 Default `POST /mcp` shape: chunked, first chunk ≤ 50 ms

Today: `POST /mcp` returns `Content-Type: application/json` with a full body after server completes processing.

New default: `POST /mcp` returns `Transfer-Encoding: chunked` with `Content-Type: application/json` and **flushes the first chunk within 50 ms**, even if the body is incomplete. The first chunk is either:

- The full body (synchronous case — completes in < 50 ms): identical wire shape to today, just chunked framing.
- A minimal JSON-RPC stub indicating streaming in progress (`{"jsonrpc":"2.0","id":..., "result":{"_streaming":true}}` — placeholder), followed by streaming chunks and a final completion chunk.

The 50 ms budget is chosen so middleboxes treat the connection as actively producing.

### 3.2 Auto-upgrade to SSE for long-running tool/LLM calls

When `POST /mcp` invokes a tool or LLM call expected to stream incrementally (signaled by the dispatcher), the *same connection* upgrades to SSE framing:

- Response header sequence (single connection):
  - `HTTP/1.1 200 OK`
  - `Transfer-Encoding: chunked`
  - `Content-Type: text/event-stream` (set lazily before first SSE frame; HTTP allows late content-type per RFC 9110 §8.3 since headers are negotiable)
- After upgrade, frames follow standard SSE shape (`event: ... \n data: ... \n\n`).
- No new connection opened; the existing chunked write stream becomes the SSE write stream.

Clients that signal `Accept: text/event-stream` start in SSE mode from frame 1. Clients with `Accept: */*` get chunked JSON until upgrade.

### 3.3 `Mcp-Session-Id` header

- Server generates `Mcp-Session-Id` on the first `POST /mcp` of a session and returns it in response headers.
- Subsequent client requests echo `Mcp-Session-Id: <id>` in request headers.
- Server uses the header to route to the correct session (compatible with stateless L7 balancers that hash on header).
- The legacy query-string keying (`?session_id=...`) remains accepted on the deprecated `GET /sse` path only — never on `POST /mcp`.

Session ID is opaque to clients (server-defined format). Recommended: URL-safe base64 of 16 random bytes.

### 3.4 Last-Event-ID resume (delegates to RFC-0099)

When client reconnects (network blip, mobile background) it sends:

```
POST /mcp
Mcp-Session-Id: <id>
Last-Event-ID: <ring-buffer-id>
```

Server delegates resume to [[RFC-0099]] PR-6's ring-buffer machinery and replays frames after `<id>`. If `<id>` is beyond TTL, server emits `event: resume_failed` and starts a fresh stream.

This RFC declares *that the header is honored*; the ring-buffer logic, capacity, and TTL knobs are [[RFC-0099]]'s.

### 3.5 Comment-keepalive (delegates to RFC-0099)

Once an SSE-upgraded connection is idle for `MASC_TRANSPORT_KEEPALIVE_SEC` ([[RFC-0099]] §3.5, default 15 s), server sends `:\n\n` (SSE comment, no event) to prevent L7 middlebox idle-drop. The interval source is [[RFC-0099]]'s env knob — this RFC does not re-introduce a parallel control.

### 3.6 Legacy `GET /sse` deprecation window

`GET /sse?sse_kind=...&session_id=...` continues to accept connections for **6 months** post-merge of PR-3 (§4). During the window:

- Response header adds `Deprecation: true` (per RFC 8594) and `Sunset: <date>` (the 6-month-out absolute date).
- Server logs an INFO line per deprecated-path request with the client's User-Agent for usage telemetry.
- Telemetry triggers `Session_lifecycle_event.Open { transport = SSE ; ... }` ([[RFC-0099]]) with a `legacy_path: true` annotation (variant extension reserved for PR-4).

Removal: after the window, `GET /sse` returns `410 Gone` with a body pointing clients to the spec.

## 4. Migration plan

| PR | Scope | Acceptance |
|----|-------|-----------|
| PR-1 (this) | RFC body | review + merge |
| PR-2 | `POST /mcp` chunked first-flush + 50 ms budget. No auto-upgrade yet (still always JSON). | first-byte latency benchmark shows P95 ≤ 50 ms; existing client smoke tests pass |
| PR-3 | Auto-upgrade to SSE on tool/LLM streaming dispatch. `Mcp-Session-Id` header generation + echo. | new test: same connection produces both JSON header and SSE frames; legacy clients (no `Accept: text/event-stream`) get chunked JSON; new clients get SSE on upgrade |
| PR-4 | `Last-Event-ID` header honored (delegates to [[RFC-0099]] PR-6) + `Deprecation`/`Sunset` headers on legacy `GET /sse` + `legacy_path: true` annotation on lifecycle event. | resume replay test (one frame drop reproduced + recovered); deprecation header visible to legacy SDKs |
| PR-5 (T+6 months) | Remove `GET /sse` path. Return `410 Gone`. | only after telemetry confirms < 1 % of traffic on deprecated path for 30 consecutive days |

PR-2 is **wire-shape-changing** (chunked framing replaces full-body); but the *body bytes* and *headers other than Transfer-Encoding* are identical, so well-behaved JSON clients consume it transparently. Misbehaved clients (parse the response as one fixed buffer) need an upgrade.

## 5. Verification

- `scripts/harness/transport/first_byte_latency.sh`: 100 sequential `POST /mcp` calls; assert P50 ≤ 30 ms / P95 ≤ 50 ms first-byte time.
- `test/test_streamable_http_upgrade.ml`: same connection serves JSON then upgrades to SSE; client receives both correctly.
- `test/test_mcp_session_id_header.ml`: server-generated header echoes correctly across 3 sequential requests.
- `scripts/harness/transport/legacy_sse_deprecation.sh`: `GET /sse` returns `Deprecation: true` + `Sunset` header; INFO log line matches User-Agent.
- 6-month window timer: telemetry counter `mcp_legacy_sse_requests_total` reaches < 1 % of `mcp_post_requests_total` for 30 days before PR-5.

## 6. Trade-offs

| For | Against |
|-----|---------|
| Spec-aligned (MCP 2025-03-26). Future client SDK upgrades land cleanly. | One-time client compatibility risk for parse-as-single-buffer clients (rare, mitigated by chunked-JSON being identical body content). |
| Single connection per request — middlebox-friendly, lower fan-out of FDs. | Auto-upgrade logic adds branching in the response pipeline; needs test coverage for both JSON-only and JSON→SSE paths. |
| `Mcp-Session-Id` header enables stateless L7 routing. | Migration cost for legacy clients still on query-string keying — covered by 6-month deprecation. |
| Composes cleanly with [[RFC-0099]] (resume + keepalive) and [[RFC-0098]] (envelope shape unchanged). | Three RFCs (0098, 0099, 0100) collectively touch the transport layer; review needs to verify they don't conflict. Mitigation: each RFC declares its layer (response edge / lifecycle / framing) explicitly. |
| 6-month deprecation honors external agent clients. | Telemetry must run for the full window before PR-5; team can't remove sooner. |

## 7. Open questions

- **Q1**: Should the 50 ms first-byte budget be configurable via env knob? **Decision (default)**: no — it's a spec/middlebox requirement, not a tunable. If a use case appears, revisit.
- **Q2**: What's the exact upgrade dispatch signal? Tool catalog metadata (`streaming: true`)? Or runtime-decided (first chunk-emit from the OAS path)? **Open** — PR-3 picks one based on which has lower wiring cost.
- **Q3**: Should server reject `POST /mcp` with `Mcp-Session-Id: <unknown>` (force re-open) or silently mint a new session? **Decision (default)**: reject with `404 Not Found` + new `Mcp-Session-Id` header — explicit handshake aligns with [[RFC-0099]]'s `Open` event being a real lifecycle transition.

## 8. Acceptance

- [ ] PR-1 (this RFC body): review + merge.
- [ ] PR-2: chunked first-flush + 50 ms latency target.
- [ ] PR-3: auto-upgrade + `Mcp-Session-Id` header.
- [ ] PR-4: `Last-Event-ID` honored + deprecation headers.
- [ ] PR-5 (T+6 months): legacy `GET /sse` removed.
- [ ] RFC promoted to `Active` at PR-3 merge; `Implemented` after PR-5.

## 9. References

- [MCP Transports (2025-03-26)](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports)
- [HTTP Semantics — RFC 9110 §8.3 (Content-Type)](https://www.rfc-editor.org/rfc/rfc9110#section-8.3)
- [HTTP Deprecation header — RFC 8594](https://www.rfc-editor.org/rfc/rfc8594)
- [[RFC-0098]] — Typed JSON-RPC error envelope (response edge, IMPROVE-01)
- [[RFC-0099]] — Session lifecycle typed events (transport edge, IMPROVE-05)
- [[RFC-0095]] — OpenAI-compat provider streaming wire-up (provider edge, in main)
- [[RFC-OAS-020]] — TTFT instrumentation in oas (IMPROVE-04)
