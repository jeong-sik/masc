---
rfc: "0281"
title: "WebSocket transport SSOT — separate upgrade-attachment from session-protocol, drive the connection"
status: Superseded
created: 2026-06-22
updated: 2026-07-10
author: vincent
supersedes: []
superseded_by: null
related: ["0100", "0204", "0106", "0138"]
implementation_prs: []
---

# RFC-0281: WebSocket transport SSOT

Status: Superseded. The connection-driving diagnosis led to the current
same-origin `/ws` path, but the standalone `:8937` listener and `MASC_WS_PORT`
topology described below were subsequently removed. Current runtime truth is
owned by `docs/spec/09-server-transport.md`.
Author: jeong-sik (vincent), with Claude Opus 4.8
Date: 2026-06-22
Scope: WebSocket transport surface — the HTTP-upgrade path (`GET /ws`, `GET /api/v1/ide/lsp`) and the standalone listener (`MASC_WS_PORT`, default 8937). Establishes a single connection-driving SSOT and a single MCP session-protocol SSOT.
Out of scope: HTTP/SSE transport (owned by [[RFC-0100]]), domain/pool isolation for dashboard reads (owned by [[RFC-0204]]), WebRTC signaling, the in-band hello/token auth protocol (unchanged).

## 1. Problem

WebSocket transport grew without an owning RFC. RFC-0100 §2 explicitly scopes itself to HTTP and lists "WS / gRPC / WebRTC transport changes" as out of scope. The result is three independent upgrade wirings, two of which never drive the connection and therefore never read an inbound frame.

| # | Site | Upgrade wiring | `ws_conn` driven? | Frame record | Status |
|---|------|----------------|-------------------|--------------|--------|
| A | same-origin `GET /ws` — `server_mcp_transport_ws.ml:1231 upgrade_connection` (via `server_routes_http_routes_frontend.ml:96`) | `Handshake.respond_with_upgrade` + `ignore ws_conn` | no | inline copy #1 (`:1262-1282`) | broken |
| B | IDE LSP `GET /api/v1/ide/lsp` — `server_ide_lsp_proxy.ml:815` | `Handshake.respond_with_upgrade` + `ignore ws_conn` (`:862`) | no | inline copy #2 (`:836-860`), `Pong` dropped → no liveness | broken |
| C | standalone listener `:8937` — `server_ws_standalone.ml:403` | `Ws_eio.Server.create_connection_handler` | yes | inline copy #3 (`:314-358`) | working |

### 1.1 Root cause — the Gluten `upgrade` capability is discarded before routing

httpun-eio hands the connection handler a `Httpun.Reqd.t Gluten.reqd`, a private record `{ reqd : Httpun.Reqd.t; upgrade : Gluten.impl -> unit }` (`httpun_eio.mli:39`, `gluten.mli:87-89`). The `upgrade` function is the only way to hand the post-101 socket to a new protocol runtime.

masc discards it at the routing boundary:

```
bin/main_eio.ml:495   let reqd = gluten_reqd.Gluten.Reqd.reqd in   (* upgrade dropped here *)
  → dispatch_route ~router ~request ~path reqd                     (* only Httpun.Reqd.t flows on *)
    → Http.Router.dispatch → route.handler (Httpun.Request.t -> Httpun.Reqd.t -> unit)
      → /ws: websocket_handler → upgrade_connection reqd
        → Handshake.respond_with_upgrade reqd (fun () -> create_websocket …; ignore ws_conn)
                                                                    (* cannot call upgrade — not in scope *)
```

The `ignore ws_conn` at A:`1284-1286` and B:`862` is not laziness; it is forced. With only `Httpun.Reqd.t` in scope there is no `upgrade` to call, so the freshly-built `Server_connection.t` (which holds the frame reader, including the correct handler that calls `read_inbound_message_frame` and `record_pong`) is never attached to the I/O loop. The 101 is sent, the session is registered, but no inbound frame is ever read.

Observable consequence: the client `hello` is never answered, the client's `DASHBOARD_WS_RPC_TIMEOUT_MS` (30s) fires, the protocol `Pong` is never read so the server's 90s missed-pong threshold closes with 1006, and the client enters a reconnect loop. `dashboard-ws.ts` flips `dashboardWsReady=false` each cycle, and `dashboard-shell` branches on that signal, re-rendering the whole shell — the user-visible "page reloads" flicker.

### 1.2 Evidence (measured 2026-06-22, browser raw-WebSocket probe, identical 64-char dev-token)

- standalone `ws://127.0.0.1:8937/` → `RECV {result:{authenticated:true, agent:"dashboard"}}` in ~11ms.
- same-origin `ws://127.0.0.1:8935/ws` → 101 sent, session registered (discovery `session_count` increments), then 12s with no response to `hello`.

Five competing hypotheses were rebutted empirically before this diagnosis: heartbeat-fiber starvation (independent fiber), H2/HTTP1.1 ALPN (loopback plaintext does not negotiate H2), snapshot slowness ([[RFC-0204]] perf, orthogonal — `hello` work is trivial), token mismatch (same token authenticates on 8937), and [[RFC-0204]] scheduling starvation (would affect both ports; 8937 is fine). The differentiator is wiring, not load: A/B never drive the connection; C does.

### 1.3 Frame-record drift

The `Httpun_ws.Websocket_connection.t` record (the opcode `match`) is hand-written three times and has diverged:

- A and C: full opcode set; `Text|Binary|Continuation → read_inbound_message_frame`; `Ping → send_pong`; `Pong → record_pong` (liveness).
- B: `Text|Binary → read_frame_text` (LSP-specific), no `Continuation` reassembly for messages, and `Pong` falls into the ignore branch, so the IDE LSP socket has no client-liveness accounting.

All three call into the same library (`module Ws = Httpun_ws` in B and C; A uses `Httpun_ws` directly; `Ws_eio = Httpun_ws_eio`). The types `Server_connection.t`, `Websocket_connection.t`, `Wsd.t` are therefore identical across sites — the duplication is incidental, not forced by a library boundary.

## 2. Non-goals / constraints

- No change to the in-band auth protocol (hello message carries the token; `/ws` has no HTTP-layer auth).
- No change to keeper affinity or domain layout ([[RFC-0204]] §2 / RFC-0059 lesson).
- No change to `read_inbound_message_frame` / `dispatch_inbound_message` semantics — these are already the shared SSOT for message handling and stay byte-for-byte identical.
- HTTP/2 does not carry WS upgrade in masc; the h2 dispatch path must reject a WS route explicitly, not silently no-op.

## 3. Design

Two orthogonal concerns are currently conflated. Separate them, and give each one owner.

### 3.1 Concern 1 — connection attachment (how bytes reach `Server_connection.t`)

Two legitimate entry mechanisms remain:

- **HTTP upgrade** (A, B): `Handshake.respond_with_upgrade` followed by `upgrade (Gluten.make (module Httpun_ws.Server_connection) ws_conn)`. This is the line masc omits.
- **Standalone listener** (C): `Ws_eio.Server.create_connection_handler` over an accepted flow.

These differ in how the socket is obtained but converge on the same obligation: build a `Server_connection.t` and drive it. The HTTP-upgrade obligation becomes a single function:

```ocaml
(* server_mcp_transport_ws.ml — SSOT for HTTP→WS attachment *)
val respond_and_drive_upgrade
  :  upgrade:(Gluten.impl -> unit)
  -> reqd:Httpun.Reqd.t
  -> handler:(Httpun_ws.Wsd.t -> Httpun_ws.Websocket_connection.t)
  -> (unit, string) result
(* = Handshake.respond_with_upgrade ~sha1 reqd (fun () ->
       let ws_conn = Server_connection.create_websocket handler in
       upgrade (Gluten.make (module Httpun_ws.Server_connection) ws_conn)) *)
```

Both A and B call this. The standalone path keeps `Ws_eio.Server.create_connection_handler` (its socket is already accepted, no HTTP upgrade involved) but uses the same `handler` builder from §3.2.

### 3.2 Concern 2 — MCP session protocol (the `wsd -> Websocket_connection.t` builder)

The session lifecycle (create session, register in `sessions`, subscribe SSE, start heartbeat) plus the opcode `match` is identical for the MCP/dashboard WS regardless of entry. Extract one builder:

```ocaml
(* server_mcp_transport_ws.ml — SSOT for the MCP WS session/frame record *)
val mcp_websocket_handler
  :  ?sw:Eio.Switch.t
  -> ?clock:_ Eio.Time.clock
  -> on_message:(string -> string -> unit)
  -> origin_label:string
  -> Httpun_ws.Wsd.t
  -> Httpun_ws.Websocket_connection.t
```

- A (same-origin): `respond_and_drive_upgrade ~upgrade ~reqd ~handler:(mcp_websocket_handler ?sw ?clock ~on_message ~origin_label:"same-origin /ws")`.
- C (standalone): `Ws_eio.Server.create_connection_handler ~sw (mcp_websocket_handler ~sw ~clock ~on_message ~origin_label:"standalone")`.

B (IDE LSP) shares §3.1 attachment but **not** §3.2: it is a different protocol (LSP dispatch, not `dispatch_inbound_message`). Its `wsd -> Websocket_connection.t` builder stays in `server_ide_lsp_proxy.ml`, but is routed through `respond_and_drive_upgrade` so it is actually driven (fixing the no-read defect).

B also has no server-side heartbeat (it never pings the client), so its `Pong` branch stays a no-op close — there is no liveness to record. (Adding a heartbeat to the LSP socket for parity with the MCP path is a possible future enhancement, out of scope here.)

Because the Gluten upgrade handler must return promptly (§3.1), B cannot keep its previous per-connection `Eio.Switch.run` + disconnect-promise scaffold (which scoped the spawned language-server processes by switch teardown). Instead, the spawned processes are bound to the server switch and reclaimed **explicitly** in `disconnect`: `Lsp_process_manager.shutdown` closes each process's stdin/stdout/stderr flows, which makes the response-reader and stderr-drain fibers' reads raise so those fibers exit — reclaiming both the processes and their fibers without a switch teardown. `disconnect` is idempotent (guarded by `disconnected`) and runs under `spawn_mutex`; it is invoked from the frame `Connection_close` and `eof` handlers, which httpun-ws delivers sequentially on the connection fiber (so it cannot race in-flight `dispatch_message`, which runs on that same fiber).

### 3.3 Threading `upgrade` to the route — typed WS route in the Router

`upgrade` exists only at `main_eio.ml:494`. Rather than match WS path strings before the router (which would create a new out-of-band classifier — the anti-pattern this RFC removes), make "this route upgrades" a typed property of the route table, keeping the route table as the SSOT for what paths exist.

```ocaml
(* http_server_eio.ml Router *)
type upgrade = Gluten.impl -> unit
type ws_handler = upgrade:upgrade -> Httpun.Request.t -> Httpun.Reqd.t -> unit
type route_handler = Plain of request_handler | Ws of ws_handler   (* route.handler *)

val ws_get : string -> ws_handler -> t -> t   (* registers a Ws route *)

val dispatch : t -> upgrade:upgrade option -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(* Matched (Ws h), upgrade=Some u  -> h ~upgrade:u request reqd
   Matched (Ws _), upgrade=None    -> 426 Upgrade Required (h2/non-upgrade transport): explicit, not silent
   Matched (Plain h)               -> h request reqd  (upgrade unused) *)
```

Existing `get`/`post`/`prefix_*` wrap their handler in `Plain`; external call sites are unchanged. `main_eio.ml` stops destructuring `gluten_reqd` early and passes `~upgrade:(Some gluten_reqd.Gluten.Reqd.upgrade)` into dispatch; the h2 gateway passes `~upgrade:None`. The `Ws _ + None` branch returns 426 so a misrouted upgrade is a visible error, never a silent drop.

`/ws` and `/api/v1/ide/lsp` move from `Router.get` to `Router.ws_get`. `websocket_handler` and the LSP handler gain `~upgrade` and call §3.1.

## 4. Purge (어중이떠중이 제거)

| Removed / replaced | Replacement |
|--------------------|-------------|
| A `ignore ws_conn` boilerplate (`transport_ws.ml:1284-1286`) | `respond_and_drive_upgrade` |
| B `ignore ws_conn` boilerplate (`ide_lsp_proxy.ml:862`) | `respond_and_drive_upgrade` |
| A inline frame record (`:1262-1282`) | `mcp_websocket_handler` |
| C inline frame record (`ws_standalone.ml:314-358`) | `mcp_websocket_handler` |
| The misleading comment "httpun-ws handles this internally when using respond_with_upgrade" | deleted (it is false) |

Net effect: one attachment SSOT, one MCP-session SSOT, one route-table-typed upgrade capability. The frame opcode `match` exists once. B's silent `Pong` drop is fixed as a side effect of routing through the shared attachment + corrected LSP record.

## 5. Verification

1. `dune build @check` — type-checks the Router variant change across all route registrations and both request-handler factories.
2. Unit: `respond_and_drive_upgrade` with a stub `upgrade` records that `Gluten.make (module Server_connection)` was applied to the `ws_conn` built from `handler` (the regression the bug represents: `upgrade` must be called exactly once).
3. Unit: `Router.dispatch ~upgrade:None` on a `Ws` route returns 426; `~upgrade:(Some _)` invokes the handler with the upgrade in scope.
4. Live parity: `hello` on `ws://127.0.0.1:8935/ws` returns `authenticated:true` within the same order of magnitude as `:8937` (was 12s no-response → expect ~tens of ms). Protocol `Pong` is read (no 90s 1006 close). Dashboard `dashboardWsReady` stays true across the heartbeat interval (no reconnect-loop flicker).
5. IDE LSP `/api/v1/ide/lsp` completes a request/response round-trip (was 101-then-silence).

## 6. Anti-pattern self-check (CLAUDE.md workaround bar)

- Not telemetry-as-fix: this drives the connection so frames are read; it does not merely count dropped frames.
- Not a string classifier: it removes the would-be path-string match by making upgrade a typed route property.
- Not N-of-M: all three sites are migrated in this change; the abstraction (`respond_and_drive_upgrade` + `mcp_websocket_handler`) makes a fourth site impossible to write divergently.
- No cap/cooldown/dedup/repair.
- No test backdoor.

## 7. Rollback

The change is additive at the Router (a new variant arm) plus three call-site rewrites. Reverting the commit restores the prior (broken) wiring. No data migration, no schema, no persisted state.
