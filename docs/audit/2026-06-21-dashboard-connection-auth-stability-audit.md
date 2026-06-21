# Dashboard connection/auth stability audit

Date: 2026-06-21 Asia/Seoul
Scope: dashboard auth bootstrap, `/ws` discovery, WebSocket/SSE fallback, runtime path/env ownership, and keeper coupling risk.

This audit is deliberately adversarial. It records what is true in current `main`, which parts are already reasonably defended, and which issues should not be treated as solved by smaller diagnostic fixes.

## External references checked

- OCaml manual 5.5, effect handlers and concurrency: https://ocaml.org/manual/5.5/effects.html
- Eio `Switch`, resource/fiber lifetime and cancellation grouping: https://ocaml-multicore.github.io/eio/eio/Eio/Switch/index.html
- WHATWG WebSockets Standard, browser connection states and constructor behavior: https://websockets.spec.whatwg.org/
- WHATWG HTML Standard, `EventSource` reconnect behavior and query-URL-only constructor: https://html.spec.whatwg.org/multipage/server-sent-events.html

Check timestamp: 2026-06-21 Asia/Seoul.

## What is already defended

1. Auth token bootstrap no longer blindly overwrites manual tokens.
   - `dashboard/src/api/dev-token.ts` preserves non-dev stored tokens and only fetches `/api/v1/dashboard/dev-token` for loopback dashboard contexts.
   - `dashboard/src/api/core.ts` moves URL tokens into session storage and shares the same bearer reader across HTTP and WebSocket hello.
   - This PR adds same-tab stored-token change notification and makes `dashboard/src/dashboard-ws.ts` close/reconnect the active socket when the token is replaced or cleared. A stale-token `dashboard/hello` rejection can now recover after a fresh dev/manual token arrives, and clearing a token no longer leaves a previously authenticated WS session alive.

2. WebSocket handshake is gated before server push fanout.
   - `dashboard/src/dashboard-ws.ts` sends `dashboard/hello` with the shared bearer token.
   - `lib/server/server_mcp_transport_ws.ml` drops dashboard push for unauthenticated WS sessions until `dashboard/hello` succeeds.

3. Per-connection cleanup is no longer obviously global.
   - WS sessions detach before closing under the sessions mutex.
   - SSE connections are registered with per-connection stop state in `lib/server/server_mcp_transport_http_conn.ml`.
   - The Eio shape matches the official `Switch` resource-lifetime contract: long-lived fibers/resources must be owned by caller-provided switches, and child failures/cancellation need explicit containment.

## P0: remote/proxy WebSocket is not actually solved

Current code:

- `GET /ws` is a discovery JSON route in `lib/server/server_routes_http_routes_frontend.ml`.
- `lib/transport_read_model.ml` returns a standalone loopback URL only when the request host is loopback.
- For remote hosts it returns `ws_url = null` with `unavailable_reason = standalone_ws_loopback_only`.
- The same JSON exposes `same_origin_ws_url`, but `same_origin_upgrade_enabled = false`.
- `Server_mcp_transport_ws.upgrade_connection` exists, but no route currently wires it into `/ws`.

Impact:

- RunPod/proxy/remote dashboards cannot connect to `ws://127.0.0.1:<MASC_WS_PORT>/`.
- The browser correctly refuses or cannot reach the loopback standalone socket.
- Before this PR, the dashboard collapsed this into `dashboard websocket unavailable`, hiding the real condition.

Required fix:

- Wire same-origin HTTP upgrade on `/ws` through the top-level route stack.
- Reuse the same inbound MCP dispatch path used by `Server_ws_standalone.start`.
- Flip discovery only after the route is wired and covered by tests: `same_origin_upgrade_enabled = true`, `ws_url = same_origin_ws_url` for remote/proxy-safe requests.
- Add an e2e smoke with an HTTPS or proxy-like origin that verifies `wss://<dashboard-origin>/ws` reaches `dashboard/hello` and `dashboard/subscribe`.

This PR only makes the diagnosis visible; it does not claim to provide remote WSS.

## P1: auth/development-token UX still needs typed failure display

Current code:

- `/api/v1/dashboard/dev-token` returns 404 on strict auth or non-loopback binds.
- `ensureDevToken()` intentionally swallows fetch failures so strict-auth servers can still reach normal 401 handling.
- WS now follows same-tab token replacement/clear events, but the user still sees this mostly as badge state changes.
- The UI has auth status surfaces, but the connection failure reason and token-source state are not shown together.

Recommended UX:

- Add one transport/auth detail drawer with:
  - token source: URL/manual/dev/none
  - dev-token status: idle/fetching/ok/no_endpoint/network
  - WS discovery reason: e.g. `standalone_ws_loopback_only`
  - last hello failure: timeout/auth rejected/policy close
  - copyable diagnostics payload

This is a UI quality issue, not an OAS/model-provider issue.

## P1: SSE is still a live fallback concept but has legacy surfaces

Current code:

- `dashboard/src/app.ts` starts WS as the primary dashboard transport.
- `dashboard/src/sse.ts` still has `connectSSE()` but no production app caller was found in the dashboard startup path.
- `dashboard/src/transports/sse-transport.ts` has an explicit reconnect contract and tests.
- EventSource cannot set arbitrary Authorization headers; current code correctly uses URL/query token paths for SSE-style observer streams.

Recommended action:

- Either formally keep SSE as a degraded fallback and document the route owner, or retire the dead client surface.
- Do not unify WS and SSE reconnect code until that product decision is made; they have different browser constraints.

## P1: keeper "one stops all" risk is lower, not zero

Current code already has several containment points:

- WS inbound dispatch is capped per session.
- WS/SSE session cleanup has per-session state.
- Dashboard slices mostly hydrate from cached snapshot surfaces.

Remaining adversarial risks:

- Shared dashboard snapshots still read global server state and some shared caches.
- Long-running snapshot or keeper lifecycle paths can still compete with dashboard/keeper compute in the same process.
- Emergency stop and per-keeper lifecycle operations need explicit blast-radius tests: one keeper stop must not cancel unrelated keeper turns or dashboard transport pumps.

Required tests:

- Start two keepers, stop one via dashboard API, verify the other keeper's turn phase and heartbeat continue.
- While one keeper is cancelled mid-tool, keep WS connected and verify `dashboard/ping` and route subscribe still succeed.

## P2: env/path ownership is documented, but scattered

Current docs correctly state that runtime root is `<MASC_BASE_PATH>/.masc`, not a bare home-relative `.masc` shorthand.

Remaining risk:

- Some runtime paths still read `Sys.getenv_opt` directly outside a narrow resolver layer.
- Some docs include machine-specific `/Users/dancer/me` examples. That is acceptable only as evidence/example text, not as runtime default.
- `MASC_WS_*` and `MASC_SSE_*` knobs are currently split across startup-time, module-init, and live-read patterns.

Recommended action:

- Declare each env knob as startup-fixed, module-init-fixed, or live-read in `docs/ENV-CONTRACT.md`.
- Prefer `Env_config_core` helpers for new code and leave direct `Sys.getenv_opt` only where the file owns environment resolution.

## UI/UX backlog

- Surface the exact transport failure reason instead of only a green/yellow/red badge.
- Add copyable diagnostics for auth + discovery + last close code.
- Keep compact header badges, but move high-cardinality detail into a drawer or popover.
- Avoid hiding strict-auth/non-loopback behavior behind generic "network" wording.
- In remote/proxy mode, show an explicit callout when standalone loopback WS is unreachable and same-origin WSS is disabled.

## Change in this PR

`dashboard/src/dashboard-ws.ts` now carries `/ws` discovery failure reasons into `dashboardWsLastError`. Existing status tray/beacon surfaces can show `dashboard websocket unavailable: standalone_ws_loopback_only` instead of an opaque unavailable state.

The dashboard auth layer now also publishes same-tab bearer-token changes. The WS layer uses that signal to close/reconnect after token replacement or token clear, so the socket authorization state tracks the stored bearer token instead of remaining stuck after `dashboard/hello` auth rejection or staying privileged after a clear.
