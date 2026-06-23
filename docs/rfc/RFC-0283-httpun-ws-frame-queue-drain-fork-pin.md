---
rfc: "0283"
title: "Backport httpun-ws frame-queue drain (upstream PR #80) via fork-pin for coalesced-fragment inbound WebSocket"
status: Draft
created: 2026-06-23
updated: 2026-06-23
author: vincent
supersedes: []
superseded_by: null
related: ["0281"]
implementation_prs: []
---

# RFC-0283: httpun-ws frame-queue drain fork-pin

Status: Draft
Author: jeong-sik (vincent), with Claude Opus 4.8
Date: 2026-06-23
Scope: The inbound WebSocket frame-reading path shared by every masc server WS endpoint — same-origin `GET /ws`, `GET /api/v1/ide/lsp`, and the standalone listener (`MASC_WS_PORT`, default 8937). All three drive `Httpun_ws.Server_connection`, whose frame queue is the subject of this RFC.
Out of scope: The connection-attachment and session-protocol SSOTs (owned by [[RFC-0281]], already merged). The in-band hello/token auth protocol. HTTP/SSE transport ([[RFC-0100]]).

## 1. Problem

[[RFC-0281]] fixed the connection-attachment defect (the socket was never handed to Gluten, so no inbound frame was read). With that fixed, a second, deeper defect is now reachable: the underlying `httpun-ws` 0.2.0 library stalls when a single logical WebSocket message arrives as **3 or more frames coalesced into one TCP read** with a non-final middle frame.

### 1.1 Root cause — `_next_read_operation` advances the frame queue one entry per socket read

When several frames arrive in one read, the angstrom parser parses all of them in one pass and pushes each `(frame, payload)` onto an internal `frame_queue`, but the queue head's `frame_handler` is invoked only for the first frame (the queue-was-empty case). The remaining frames sit in the queue undelivered. The runtime then calls `_next_read_operation` to decide the next step:

```
(* httpun-ws 0.2.0 lib/websocket_connection.ml:95-109 *)
| Complete ->
  begin match Reader.next t.reader with
  | `Error _ as op -> op
  | `Read as op ->
    advance_frame_queue t;   (* advances exactly ONE entry, delivers ONE frame *)
    op                       (* returns `Read WITHOUT recursing *)
  | `Close ->
    advance_frame_queue t;
    _next_read_operation t   (* only this branch drains the rest of the queue *)
  end
```

`advance_frame_queue` (`websocket_connection.ml:77-83`) dequeues one entry and delivers one frame. The `` `Read `` branch advances once and returns `` `Read ``; only the `` `Close `` branch recurses. So when the parser is in a partial state (`` `Read ``, the normal case after consuming a buffer of coalesced frames), the runtime is told "go read the socket" while frames remain queued. The gluten-eio read loop then blocks on a socket read that will not return — the client, waiting for its reply, sends nothing further. Deadlock.

This is purely library-internal. masc's `read_payload_string` (`lib/server/server_mcp_transport_ws.ml:937`) receives already-decoded frames through the push-based `frame` callback (`lib/server/server_mcp_transport_ws.ml:1328`) and has no handle on `advance_frame_queue` — no masc-side change can drive the drain. The defect lives below masc's boundary.

### 1.2 Reachability

A browser `WebSocket.send()` emits each call as one unfragmented frame (HTML Living Standard), so today's shipped clients — the dashboard `/ws` client and the IDE LSP client, both browser-native — cannot trigger this. The exposure opens when a non-browser client with a raw framer connects (a raw OCaml MCP-over-WS client, a load tester, or a re-fragmenting intermediary). The owner has confirmed such a client is plausible, which is why this is fixed proactively rather than deferred.

### 1.3 Evidence (measured 2026-06-23, standalone reproduction)

A minimal program depending only on `httpun-ws` 0.2.0, replicating masc's `read_payload_string` handler byte-for-byte and feeding three masked client frames (`Text` fin=0, `Continuation` fin=0, `Continuation` fin=1) as one coalesced read:

- stock 0.2.0: 2 of 3 fragments delivered, final fragment (`is_fin=true`) never seen, `next_read_operation` returns `` `Read `` → stall.
- with PR #80's one-line change applied: 3 of 3 delivered, message complete, no stall.

Upstream PR #80 (open, unmerged) is exactly this fix: it replaces `advance_frame_queue t; op` with `advance_frame_queue t; _next_read_operation t` so the queue drains before the socket is polled. No released `httpun-ws` carries it (0.2.0 is latest; master is still buggy). Related upstream issue #77 (delayed pongs) is the same defect surfaced on control frames. Tracking: jeong-sik/masc#22100.

## 2. Non-goals / constraints

- Not a masc-side workaround. The fix is the upstream change applied to the library; masc cannot reach the queue.
- No change to masc application code beyond a regression test. The dependency pin is the only shipped change.
- Pin both `httpun-ws` and `httpun-ws-eio` (same source repo, must move together).
- Temporary by construction: the pin is removed when upstream releases a version carrying PR #80.

## 3. Design

### 3.1 Fork-pin

Apply PR #80's one-liner to a masc-owned fork of `anmonteiro/httpun-ws` and pin both packages to it, following the existing `bisect_ppx` precedent (`scripts/opam-pin-external-deps.sh:346` pins `bisect_ppx` to `git+https://github.com/patricoferris/bisect_ppx.git#5.2`; `masc.opam.locked:218-225` records the matching `pin-depends`).

- `scripts/opam-pin-external-deps.sh`: add `opam_pin_add httpun-ws` and `httpun-ws-eio` to the fork's git URL + branch.
- `masc.opam.locked`: add `pin-depends` entries for `httpun-ws.0.2.0` and `httpun-ws-eio.0.2.0` pointing at the fork commit.
- `masc.opam` / `dune-project` version constraints (`>= 0.2`) are unchanged — the fork keeps version 0.2.0.

### 3.2 Companion regression test

A test that drives the **real** `Httpun_ws.Server_connection` frame queue (not masc's `inbound_accumulate`, which bypasses the library) with three coalesced fragments and asserts all three are delivered. It fails on stock 0.2.0 and passes with the pin, so it both proves the bug and guards the fix. This closes the gap noted in [[RFC-0281]] §5, where the inbound tests bypass the library frame queue.

## 4. Anti-pattern self-check (CLAUDE.md workaround bar)

The recommended path is patch-the-library-at-the-bug-site. It carries none of the rejected signatures: no telemetry-as-fix, no string classifier, no N-of-M, no cap/cooldown/dedup/repair. The explicitly rejected alternative — masc forcing extra reads or otherwise poking the runtime from outside — would be a workaround, because the frame queue is library-internal and any masc-side mitigation is symptom suppression by construction. A faithful upstream fix applied via a dependency pin is a root fix.

## 5. Verification

- Standalone reproduction (§1.3): stock RED, patched GREEN — recorded in jeong-sik/masc#22100.
- Companion regression test (§3.2): RED on stock, GREEN with the pin.
- masc build + full test suite with the pin active (CI on the implementation PR).

## 6. Removal target

Remove the pin when upstream `anmonteiro/httpun-ws` releases a version carrying PR #80 (or an equivalent drain fix). An upstream PR referencing this reproduction is opened in parallel. Until then the fork is the source of truth and is tracked in jeong-sik/masc#22100.

## 7. Rollback

Revert the pin-depends and `opam-pin-external-deps.sh` changes; masc returns to stock `httpun-ws` 0.2.0. The regression test then fails (correctly), documenting the reintroduced defect. Because no masc application code changes, rollback is a dependency-only revert.
