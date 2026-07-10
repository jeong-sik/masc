---
rfc: "0287"
title: "ws-direct — a single masc-owned WebSocket stack for server and client"
status: Implemented
created: 2026-06-23
updated: 2026-07-10
author: vincent
supersedes: []
superseded_by: null
related: ["0281", "0203", "0100", "0204"]
implementation_prs: []
---

# RFC-0287: ws-direct — a single masc-owned WebSocket stack

Status: Implemented for the same-origin server upgrade and outbound client
stack. The standalone-listener sections below are historical: that listener,
`:8937`, and `MASC_WS_PORT` were later retired in favor of one HTTP-listener
`/ws` boundary. Current topology is in `docs/spec/09-server-transport.md`.
Author: jeong-sik (vincent), with Claude Opus 4.8
Date: 2026-06-23
Scope: the WebSocket library under the transport surface — the server upgrade
path (`GET /ws`, `GET /api/v1/ide/lsp`), the standalone listener (`MASC_WS_PORT`,
default 8937), and the Discord gateway client (`wss://`). Replaces two
third-party WebSocket libraries with one masc-owned codec.
Out of scope: the connection-driving SSOT and session protocol established by
[[RFC-0281]] (this RFC swaps the library *under* that SSOT, not the SSOT); the
HTTP/SSE transport ([[RFC-0100]]); dashboard read isolation ([[RFC-0204]]); the
in-band hello/token auth protocol (unchanged).

## 1. Problem

masc runs **two** third-party WebSocket stacks, each with an impedance mismatch
against masc's world (Eio + httpun/gluten + TLS-as-flow):

| Role | Library | Pain |
|---|---|---|
| Server (`/ws`, dashboard, IDE-LSP, `:8937`) | `httpun-ws` 0.2.0 | A frame-queue coalescing bug stalls a one-frame-per-read drainer. A fork-pin was *proposed* (PR #22111, unmerged — it also collided on the RFC-0283 number) but never landed, so main runs stock 0.2.0 with the bug. Upstream PR #80 unmerged. |
| Discord client (`wss://` outbound) | `ocaml-websocket` 2.17 | `Httpun_ws_eio.Client.connect` wants an fd-backed socket, but TLS is a flow (`Tls_eio.t`, no fd). [[RFC-0203]] worked around this with `Websocket.Make(Cohttp_eio.Private.IO)` — a functor over a library-private module. |

Both are byte-transport adapters around RFC 6455 framing. masc owns neither, so a
framing bug becomes a fork-pin, and a missing client backend becomes a
private-module dependency.

This compounds the gap [[RFC-0281]] identified: three independent server upgrade
wirings each carry their own inline frame-reassembly copy. Replacing the library
with one that reassembles internally removes those copies as a side effect.

## 2. Decision

Build and adopt **`ws-direct`**, a masc-owned WebSocket library (the
`-direct` family, alongside `grpc-direct` and `ocaml-webrtc`), pinned by git SHA
the same way. One codec serves both roles:

```
ws-direct-core    runtime-agnostic RFC 6455 codec (deps: bigstringaf, faraday)
  Frame           parse/serialize, masking, payload-len 7/16/64 + minimal-length
  Connection      full coalesced-frame drain + continuation reassembly +
                  incremental UTF-8 (§8.1) + close-code validation (§7.4.1)
  Close_code      abstract type: a reserved code (1005/1006/1015) is
                  unrepresentable, so it cannot be put on the wire
  Endpoint        a driven endpoint exposing the exact gluten RUNTIME operations
ws-direct-gluten  server adapter: Endpoint satisfies Gluten.RUNTIME (compiler-
                  proven), so `upgrade (Ws_direct_gluten.impl endpoint)` is a
                  drop-in for `Gluten.make (module Httpun_ws.Server_connection)`
ws-direct-eio     drivers over Eio.Flow.two_way (compose with Tls_eio.t):
                  Client (handshake + read/write loop) and Server (handshake +
                  drive), for the Discord client and the standalone listener
```

Repository: `github.com/jeong-sik/ws-direct` (public, MIT). The connection-driving
SSOT and session protocol from [[RFC-0281]] are unchanged; only the library that
backs them changes.

### 2.1 Why C (write it) over A/B (consolidate onto one third-party lib)

- **B — consolidate onto `ocaml-websocket`**: blocked on the server. The server
  contract is `gluten.mli`'s `module type RUNTIME`, plugged in at
  `server_mcp_transport_ws.ml:1369` via `Gluten.make (module Httpun_ws.Server_connection)`;
  `http_server_eio.ml:450` types the capability as `upgrade = Gluten.impl -> unit`.
  Gluten owns the post-upgrade socket; `ocaml-websocket` (pull-based
  `make_read_frame`, Buffer-based) cannot be attached without replacing the HTTP
  server.
- **A — consolidate onto `httpun-ws`**: possible but inherits the fork-pin and the
  fd-vs-flow client gap (a manual driver would still be needed for TLS).
- **C** owns the integration point, so one codec serves both roles and removes the
  fork-pin, the private-IO hack, and the fd impedance at once.

## 3. Conformance evidence

`ws-direct` is validated before adoption, not asserted:

- **Unit (in-repo):** 79 tests — frame golden vectors (RFC 6455 §5.7) + qcheck
  round-trips, coalesced-fragment drain, incremental UTF-8 (overlong / surrogate
  / out-of-range / split-across-fragments), typed close-code validation, the §1.3
  handshake-accept golden, and a real socketpair client↔server round-trip.
- **Autobahn (`crossbario/autobahn-testsuite`, 2026-06-23):** the `fuzzingclient`
  against a ws-direct echo server, sections 1–7, 9, 10 — **301 cases, 0 FAILED**
  (241 OK + 3 NON-STRICT [6.4.2–4 UTF-8 fail-fast timing, all close 1007] + 3
  INFORMATIONAL; section 9 large/fragmented messages 54/54 OK). Sections 12/13
  (permessage-deflate) are out of scope: ws-direct does not negotiate the
  compression extension. Config + result: `ws-direct:autobahn/`.

Because the gluten server adapter and the eio server both drive the **same**
`Endpoint`, this Autobahn run exercises the conformance the production gluten path
reuses. Section 9 specifically covers the large/coalesced-frame failure mode that
motivated the httpun-ws fork-pin.

**Performance is not claimed here.** The design avoids known slow paths
(zero-copy bigstring framing, the coalesced-frame stall, the Buffer/private-IO
client indirection), but any "faster than the current stack" statement requires a
benchmark of large-frame (dashboard-snapshot-class) parse/serialize throughput,
done at integration time (§5.3).

## 4. How the masc sites map

### 4.1 Server upgrade (`server_mcp_transport_ws.ml`, `server_ide_lsp_proxy.ml`)

Today `respond_and_drive_upgrade` does:

```
Httpun_ws.Handshake.respond_with_upgrade ~sha1 reqd (fun () ->
  let ws_conn = Httpun_ws.Server_connection.create_websocket handler in
  upgrade (Gluten.make (module Httpun_ws.Server_connection) ws_conn))
```

After: the HTTP 101 response is written on the `Httpun.Reqd.t` directly (masc
already depends on `httpun`; the accept token is SHA-1(key ^ GUID) base64, the
same `sha1` already in `test_ws_transport.ml`), then:

```
let endpoint = Ws_direct_core.Endpoint.create Server (fun wsd -> builder wsd) in
upgrade (Ws_direct_gluten.impl endpoint)
```

The handler maps field-for-field:

| httpun-ws | ws-direct |
|---|---|
| `handler : Wsd.t -> input_handlers` | `builder : Endpoint.Wsd.t -> Endpoint.handlers` |
| `input_handlers.frame ~opcode ~is_fin ~len payload` + manual reassembly (`Ws_inbound`, `read_data_frame`) | `~on_message:(fun msg -> ...)` — Connection already reassembles + UTF-8-validates |
| `\`Ping -> send_upgrade_pong; Payload.close` | auto-pong is in Endpoint; `~on_ping` optional |
| `\`Pong -> record_pong` | `~on_pong:(fun _ -> record_pong ...)` |
| `\`Connection_close -> cleanup` | `~on_close:(fun ~code ~reason -> cleanup ...)` |
| `eof` | `~on_eof` |
| `Wsd.send_bytes ~kind:\`Text` / `send_ping` / `send_pong` / `close ?code` / `is_closed` | `Endpoint.Wsd.send_text` / `send_ping` / `send_pong` / `send_close ?code` / `is_closed` |

The inline frame-reassembly copies [[RFC-0281]] §1 flags (`:1262-1282`,
`:836-860`, `:314-358`) collapse into the single `on_message`.

### 4.2 Standalone listener (`server_ws_standalone.ml`)

`Ws_eio.Server.create_connection_handler` over a raw TCP flow becomes
`Ws_direct_eio.Server.handle flow builder` — the same accept-then-drive shape, no
HTTP layer.

### 4.3 Discord client (`discord_wss_connection.ml`, `discord_gateway_client.ml`)

The hardest mapping: today the gate does a blocking `read_frame () : Websocket.Frame.t`.
ws-direct's Client is callback-driven (`on_message`). Bridge it with an
`Eio.Stream`: the Client's `on_message`/`on_close` push into a stream, and
`Discord_wss_connection.read` becomes `Eio.Stream.take`, preserving the gate's
reader-loop shape. `discord_gateway_client.ml`'s `Websocket.Frame.{opcode,content}`
match becomes a match on the ws-direct message/close event. Writes go through
`Endpoint.Wsd.send_text`. The CSPRNG mask key is injected (`Mirage_crypto_rng`).

## 5. Migration plan (staged — two PRs, each independently buildable)

The swap is transport-critical (MCP `/ws`, dashboard, IDE-LSP, Discord). It is
staged so each PR is built, tested, and revertable on its own.

0. **Pin** (this RFC's companion change): add `ws-direct` to
   `scripts/opam-pin-external-deps.sh` (`WS_DIRECT_SHA` constant +
   `opam_pin_add ws-direct-core/ws-direct-gluten/ws-direct-eio`), `masc.opam.locked`
   `pin-depends`, and `dune-project`. Pin SHA: `c1dc564` (github.com/jeong-sik/ws-direct).

1. **PR 1 — server**: swap `server_mcp_transport_ws.ml`, `server_ide_lsp_proxy.ml`,
   `server_ws_standalone.ml` to `Ws_direct_gluten` / `Ws_direct_eio.Server`;
   write the 101 handshake on the reqd; change `ws_session.wsd` to
   `Endpoint.Wsd.t`; drop the inline reassembly. Remove `httpun-ws`,
   `httpun-ws-eio` from `dune-project`, `lib/server/dune`, `lib/dashboard/dune`,
   `lib/operator/dune`. Verify: `dune build`,
   `test_ws_transport`, live `/ws` hello round-trip.

2. **PR 2 — Discord client**: swap `discord_wss_connection.ml` to
   `Ws_direct_eio.Client` with the `Eio.Stream` bridge; adapt
   `discord_gateway_client.ml` opcode handling. Remove `websocket` from
   `dune-project` and `lib/gate/dune`. Supersede the [[RFC-0203]] stack choice.
   Verify: `dune build`, Discord writer test, live HELLO→heartbeat→ACK.

3. **Benchmark** (§3): large-frame parse/serialize throughput vs the prior stack,
   before any performance claim.

PR #22111 (the proposed httpun-ws fork-pin) was never merged — main runs stock
`httpun-ws` 0.2.0 with the coalescing bug — so PR 1 is the first landed fix for
this defect, not a replacement for an interim. PR 1 removes the httpun-ws
dependency entirely; #22111 is then closed as superseded by this RFC (its
3-coalesced-fragment regression is reproduced in the ws-direct Connection
harness). #22111 also carried an RFC-0283 number that is now held by an
unrelated merged RFC (fusion-judge-of-judges); ws-direct uses RFC-0287.

## 6. What this does not touch

- `httpun` / `httpun-eio` / `gluten` — only the WS protocol is replaced; the HTTP
  server and the gluten upgrade boundary stay.
- `cohttp` / `cohttp-eio` — used by OAS/GraphQL/telemetry; the Discord client
  stops using `Cohttp_eio.Private.IO`, but the dep remains for other users.
- TLS setup (`tls-eio` / `ca-certs`) — reused for the Discord connection.
- The [[RFC-0281]] driving SSOT and session protocol.

## 7. Risks / rollback

- **WS framing is a security boundary.** A hand-rolled codec risks
  unmasked-accept / payload-len overflow / control-frame DoS / invalid-UTF-8
  pass-through. Mitigation: the §3 harness (qcheck + golden + typed close codes)
  and the Autobahn run; both are prerequisites, already met.
- **Each PR is isolated.** A regression reverts to the prior library (httpun-ws
  fork-pin for the server, ocaml-websocket for Discord) without touching the
  other role. `ws-direct` is an independent repo, so it cannot destabilise masc
  except through the pinned SHA.
- **Discord callback rework** (§4.3) is the riskiest mapping; it is the second,
  separate PR for that reason, with the live HELLO→heartbeat→ACK check as the
  gate.

## 8. Alternatives considered

- **Keep two stacks, fix httpun-ws upstream**: leaves the fork-pin and the
  private-IO client hack; does not give masc ownership of the framing boundary
  that bit it.
- **A / B consolidation onto one third-party lib**: rejected in §2.1.
