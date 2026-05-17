---
rfc: "0099"
title: "Session lifecycle — typed events, explicit eviction, resume backpressure"
status: Draft
created: 2026-05-17
updated: 2026-05-17
author: vincent
supersedes: []
superseded_by: null
related: ["0098"]
implementation_prs: []
---

# RFC-0099 — Session lifecycle: typed events, explicit eviction, resume backpressure

Status: Draft
Author: jeong-sik (vincent)
Date: 2026-05-17
Scope: SSE / WS / gRPC / WebRTC session lifecycle uniformity at the transport layer
Out of scope: timeout layering (covered by `docs/TIMEOUT-MATRIX.md`), Streamable HTTP migration (IMPROVE-02, awaits in-flight #15722/#15725), FD accounting (IMPROVE-03)
Series: **IMPROVE-05** of the masc-mcp + oas improvement series. Sibling RFCs: [[RFC-0098]] (typed envelope, IMPROVE-01).

## 1. Problem

masc-mcp runs four streaming transports today (SSE, WebSocket, gRPC, WebRTC). Each has its own client-cap, eviction, idle-cleanup, and keep-alive policies. The current state has three concrete defects.

### 1.1 Silent eviction at the SSE 200-client cap

`server_mcp_transport_http_sse.ml` enforces a `max_clients = 200` cap by evicting the oldest connection. The eviction **closes the connection without sending a close frame**: from the client's perspective, the connection just drops mid-stream with no indication of *why*. Clients that auto-reconnect race with the cap and may flap; clients that don't reconnect miss subsequent events silently.

This is the transport-layer analog of [[RFC-0098]]'s silent-failure problem: a server policy decision (eviction) is invisible to the client.

### 1.2 Mailbox-full has no documented drop policy

Per-session SSE mailbox is `Eio.Stream.t` with `capacity = 1024`. When a slow consumer doesn't drain, `Stream.add` blocks. Today the broadcast loop uses non-blocking `Stream.add` semantics that silently drop or block depending on call path. Behavior is *not documented* and *not testable*. A 6-hour soak test can't assert "drop count = 0" because the policy isn't pinned.

### 1.3 Transport keep-alive policies are scattered

Each transport sets its own keep-alive interval:
- SSE comment-keepalive: not implemented at transport layer (keeper-level 30s heartbeat exists but is a different concern)
- WS ping interval: hard-coded in `server_websocket_transport.ml`
- gRPC keepalive: hard-coded in grpc layer
- WebRTC offer: 60s in `server_webrtc_transport.ml`

ALB / Cloudflare-style middleboxes drop idle connections at ~60s. Without a *uniform, configurable* keep-alive, transports drift and one transport's policy change orphans the others.

## 2. Non-goals

- **Timeout layer redesign.** `docs/TIMEOUT-MATRIX.md` owns the inner Tool / MCP / OAS / Keeper timeout chain. This RFC is about *transport-edge* session lifecycle (open/upgrade/resume/evict/close), not about how long a tool may run.
- **Streamable HTTP migration.** [[RFC-0098]] documents IMPROVE-02 (Streamable HTTP as default) which awaits in-flight PRs #15722/#15725. This RFC operates on the current SSE/WS/gRPC/WebRTC stack regardless of that migration.
- **FD accounting.** WS-C RFC (IMPROVE-03) handles FD ceiling / pool accounting. This RFC's `Backpressure_shed` close frames will *consume* FD-pressure signals from that RFC once it lands.
- **Adding a fifth transport.** Coverage of the existing four is the goal.
- **Wire-format changes inside an active stream.** Close frames are added on stream termination only; in-stream frame shape is unchanged.

## 3. Design

### 3.1 `Session_lifecycle_event.t` (typed bus signal)

New module `lib/server/session_lifecycle_event.ml(i)`:

```ocaml
type transport = SSE | WS | GRPC | WebRTC

type t =
  | Open      of { transport : transport ; session_id : string ; origin : string }
  | Upgrade   of { transport_from : transport ; transport_to : transport ; session_id : string }
  | Resume    of { transport : transport ; session_id : string ; last_event_id : string option ; replayed : int }
  | Evict     of { transport : transport ; session_id : string ; reason : evict_reason }
  | Close     of { transport : transport ; session_id : string ; reason : close_reason }

and evict_reason =
  | Cap_exceeded      (** oldest-eviction at max_clients cap *)
  | Idle_timeout      (** cleanup_stale beyond MASC_TRANSPORT_IDLE_EVICT_SEC *)
  | Backpressure      (** mailbox-full beyond drain grace *)
  | Policy_revoked    (** auth / quota / admin action *)

and close_reason =
  | Client_disconnected
  | Server_shutdown
  | Server_error of string
  | Evicted of evict_reason  (** mirror after evict→close transition *)
```

Published on the existing `Event_bus.Custom("session_lifecycle", json)` channel — same bus pattern as keeper events. Dashboard `Keeper Roster` / `Session Health` panels consume it.

Closed sum. Adding a new variant requires RFC discussion (same discipline as [[RFC-0098]]'s `Mcp_error_code`).

### 3.2 Explicit eviction close frames

On any `Evict { reason ; _ }`, the transport sends a final frame **before** closing the FD:

- **SSE**: `event: evicted\ndata: {"reason":"<wire-name>","retry_after_ms":<int>}\n\n` — clients implementing the `EventSource` API receive a parseable `evicted` event.
- **WS**: close code 4001..4099 (application range) keyed by `evict_reason`:
  - `Cap_exceeded`     → 4001
  - `Idle_timeout`     → 4002
  - `Backpressure`     → 4003
  - `Policy_revoked`   → 4004
  With UTF-8 close reason text matching the wire-name.
- **gRPC**: trailer-only error response with `Status = ABORTED` + `reason` in trailing metadata key `x-evict-reason`.
- **WebRTC**: data-channel close with reason string + ICE teardown.

**No silent drops** — close frame writes are best-effort within a 100 ms grace; if the write itself errors, that's the only acceptable silent fallback (the FD is gone, nothing more to do).

### 3.3 Mailbox backpressure semantics

Per-session SSE mailbox capacity = 1024 (unchanged). Broadcast policy:

```
try Eio.Stream.add stream frame
with
| Eio.Cancel.Cancelled _ as e -> raise e
| _ when Stream.length stream >= capacity ->
    (* drain grace: wait up to 1s for consumer to catch up *)
    if drain_within ~timeout:1.0 stream then Stream.add stream frame
    else (
      emit Session_lifecycle_event.Evict
        { transport = SSE ; session_id ; reason = Backpressure } ;
      close_with_evicted_frame ~reason:Backpressure_shed
    )
```

Drop count: explicitly **zero** by construction. A consumer that can't keep up gets evicted (with notification) and reconnects via Last-Event-ID resume (§3.4).

### 3.4 Last-Event-ID resume (SSE only; gRPC/WS use native reconnect)

SSE session-scoped ring-buffer (capacity 256 frames, TTL 300 s) — already part of [[RFC-0098]]'s IMPROVE-02 plan. This RFC pins its acceptance criteria:

- Reconnect with `Last-Event-ID: <id>` header replays frames *after* the named id.
- Each replayed frame increments the new session's `replayed` counter in `Resume { replayed ; _ }`.
- If `<id>` is beyond TTL, server sends `event: resume_failed` and forces a fresh `Open`.

### 3.5 Transport keep-alive SSOT

New env knobs (single source for all four transports):

| Env var | Default | Effect |
|---|---|---|
| `MASC_TRANSPORT_KEEPALIVE_SEC` | 15 | SSE comment-keepalive, WS ping, gRPC keepalive, WebRTC datachannel ping |
| `MASC_TRANSPORT_IDLE_EVICT_SEC` | 1800 | `cleanup_stale` interval; idle session evicted past this |
| `MASC_TRANSPORT_RESUME_WINDOW_SEC` | 300 | SSE ring-buffer TTL |
| `MASC_TRANSPORT_MAX_CLIENTS` | 200 | per-transport cap (each transport interprets) |

`docs/TIMEOUT-MATRIX.md` extended with a new `## Transport edge` section that **points** to this file (no duplication). The 4 knobs above are the *only* keep-alive surface; per-transport hard-coded constants become CI-banned in the transport modules.

## 4. Migration plan

| PR | Scope | Acceptance |
|----|-------|-----------|
| PR-1 (this RFC + Phase-0) | RFC body only. No code. | review + merge |
| PR-2 | `Session_lifecycle_event` module + Event_bus publish from SSE transport's existing eviction/cleanup sites. Inert wire (no close frame yet) — only the typed event is emitted. | dashboard event panel surfaces lifecycle events; new module compiles in isolation |
| PR-3 | SSE explicit `event: evicted` frame + mailbox backpressure semantics + close-frame writes for the 4 evict_reason variants. | `test_session_eviction.ml` asserts frame delivery for each reason; soak test shows 0 silent drops |
| PR-4 | WS close codes + gRPC trailer + WebRTC datachannel close. | per-transport tests; close-frame round-trip with a representative client per transport |
| PR-5 | Transport keep-alive SSOT — 4 env knobs + per-transport interpretation + CI lint banning hard-coded constants in transport modules | `rg -nE '(60|30|15|1800)' lib/server/server_*_transport.ml` returns 0 outside the 4 env-knob readers |
| PR-6 (optional) | Last-Event-ID resume implementation. May land separately if scope creep. | `test_streamable_http_resume.ml` from IMPROVE-02 plan |

PR-2 is **wire-inert** (Event_bus only). PR-3 introduces the first client-visible close frame. PR-4 fans out. Each is reviewable in isolation.

## 5. Verification

- `test/test_session_lifecycle_event.ml`: variant round-trip + JSON encoding stability.
- `test/test_session_eviction.ml`: drive 201 concurrent SSE connections; assert the evicted client receives `event: evicted` with `reason: cap_exceeded`.
- `test/test_mailbox_backpressure.ml`: synthetic slow consumer; assert evict-after-1s-grace + `event: evicted` + ring-buffer state preserved for the *other* clients (no cross-contamination).
- `scripts/harness/transport/soak.sh` (existing): 6-hour run; assert `silent_drop_count == 0` from the lifecycle event tally.
- `bash scripts/check-doc-truth.sh`: verify the 4 env knobs match what `Env_config_*` actually exports.

## 6. Trade-offs

| For | Against |
|-----|---------|
| Closes the silent-eviction class at the transport edge — matches RFC-0098's bar at the response edge. | 5-PR migration; full closure takes a sprint. |
| Closed-sum `evict_reason` / `close_reason` forces RFC-level discussion for new reasons. | Existing free-form log messages need conversion; one-time migration cost. |
| 1-second backpressure grace tolerates client jitter without dropping frames. | Adds a 1s tail latency on the slow path; acceptable since the alternative is silent drop. |
| Single env-knob surface ends drift between transports. | One env change affects all four; deliberate. Per-transport override deferred to a future RFC if real need surfaces. |
| Compose cleanly with IMPROVE-03 (FD accounting) — `Backpressure_shed` close frame can be triggered from FD-pressure signal. | Hard dependency: PR-3's backpressure path semantically depends on FD accounting once IMPROVE-03 lands; until then, only mailbox-full triggers it. |

## 7. Open questions

- **Q1**: Should `Resume.replayed` include a checksum / hash to let clients detect ring-buffer corruption? **Decision (default)**: no — adds complexity for a fault class that is itself silent (ring corruption is server-side). Revisit if a real incident appears.
- **Q2**: Should `Idle_timeout` reason carry the last activity timestamp? **Open** — PR-2 leaves the variant payload narrow; PR-3 considers based on dashboard need.
- **Q3**: WS close code 4001..4099 conflicts with any existing application semantics? **Audit**: `git grep '40[0-9][0-9]' lib/server/server_websocket_transport.ml` — verify in PR-4.

## 8. Acceptance

- [ ] PR-1 (this RFC body): review + merge.
- [ ] PR-2: typed event + bus publish — dashboard surface receives lifecycle events.
- [ ] PR-3: SSE close frames + mailbox backpressure semantics.
- [ ] PR-4: WS / gRPC / WebRTC close frame fan-out.
- [ ] PR-5: keep-alive SSOT + CI hard-coded constant ban.
- [ ] PR-6 (optional): Last-Event-ID resume.
- [ ] RFC promoted to `Active` at PR-3 merge; `Implemented` after PR-5.

## 9. References

- [[RFC-0098]] — Typed JSON-RPC error envelope (sibling, IMPROVE-01)
- [MCP Transports (2025-03-26)](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports)
- [WebSocket Close Codes — RFC 6455 §7.4.2](https://www.rfc-editor.org/rfc/rfc6455#section-7.4.2)
- [gRPC Status Codes](https://grpc.io/docs/guides/status-codes/)
- [Server-Sent Events — MDN](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events)
- `docs/TIMEOUT-MATRIX.md` — inner-layer timeout SSOT (complementary)
