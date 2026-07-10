---
status: implemented
last_verified: 2026-07-10
code_refs:
  - dashboard/src/dashboard-ws-cutover.ts
  - dashboard/src/dashboard-transport-fallback.ts
  - dashboard/src/sse.ts
  - dashboard/src/transports/sse-transport.ts
  - dashboard/src/components/transport-beacon.ts
  - dashboard/.env.development
---

# SSE → WebSocket Cutover

> Status: WS-primary cutover with authenticated SSE fallback and observable
> transport ownership.
> Companion doc: `docs/design/ws-migration-perf-series.md` (technical
> background — why parallel mode exists and the perf series that
> preceded this cutover).

## Why

The dashboard historically opened both an `/sse` EventSource and a `/ws`
WebSocket in parallel.  The server fans every broadcast to both
channels, so every event reaches the client twice.  WS-only mode
eliminates the duplication.  Cutover is gated behind a flag because the
dashboard is the most observable client surface and we want operators
to see the transport switch with their own eyes before retiring the
SSE plumbing.

## How to enable

| Environment | Mechanism |
|-------------|-----------|
| Dev (`pnpm --filter masc-dashboard dev`) | `dashboard/.env.development` ships with `VITE_DASHBOARD_WS_ONLY=true` |
| Production (`make build` / `pnpm --filter masc-dashboard build`) | `dashboard/.env.production` ships with `VITE_DASHBOARD_WS_ONLY=true` |
| Staging | Same as production unless `--mode staging` is invoked with a custom `dashboard/.env.staging` |
| One-off opt-out | Create `dashboard/.env.production.local` with `VITE_DASHBOARD_WS_ONLY=` (or `=false`); `.local` overrides the tracked file and is git-ignored |

The flag is build-time: `vite build` reads `.env.production` (and `.env`,
`.env.local`) automatically; `vite serve` reads `.env.development`.
A rebuild is required to flip the tracked default; for a single browser
tab without a rebuild, use the runtime injection below.

The Dockerfile rebuilds the SPA in a Node 20 stage every Railway deploy,
so the cutover flag in `dashboard/.env.production` is applied to every
production image automatically.  See `Dockerfile` (`dashboard-builder`
stage) and `.dockerignore` (whitelist for `dashboard/.env.production`).
Operators who run `make build` locally still get the same default
because both paths read the same env file.

## Reading the beacon

The transport beacon sits in the header strip next to the connection
status chip.  States:

| Color | Label | Meaning | Action |
|-------|-------|---------|--------|
| Gray | `Client WS+SSE parallel` | Explicit parallel mode is active | Duplicate delivery is expected by operator choice |
| Green | `Client WS · open · N events / 60s` / `Client WS · heartbeat · Nms` | Cutover active, socket open, events or heartbeat pongs arriving | None — the transport is healthy |
| Yellow | `Client WS · silent` | Cutover active, socket open, but no event or fresh heartbeat pong | Verify the workload is genuinely idle. If you expect events and fallback/parallel mode would show them, inspect WS fan-out |
| Red | `Client WS · disconnected` | Cutover active, but the socket is closed and no fallback is active yet | Wait for auto-reconnect; fallback should engage after the WS layer reports a failure reason |
| Yellow | `Client SSE fallback` | WS-primary mode detected a WS close/error/RPC timeout and opened authenticated `/mcp` streaming-fetch SSE | Treat as degraded-but-live; inspect the beacon title / status tray reason, then fix the WS path |

## Automatic SSE fallback

WS-only is the steady-state cutover mode, but a failed WS channel does not
pause live dashboard events. `dashboard-transport-fallback.ts` owns the
mutually exclusive lifecycle. A concrete WS error, unavailable browser WS API,
or a ready-to-reconnecting transition opens `/mcp?sse_kind=observer` through
`fetch + ReadableStream + Authorization` while the WS reconnect loop continues.
Once `dashboard/hello` and route subscription make WS ready again, the fallback
fetch is aborted so steady-state duplicate delivery stays off.

The SSE parser follows the event-stream line contract, including CRLF/LF/CR,
id-only prime frames, `retry`, chunk boundaries, and EOF discard. Bearer
rotation aborts the old request and reconnects with the current credential;
the token is never placed in the URL.

The status tray reports this state as `SSE fallback` and includes the WS
failure reason.  This is intentionally not a full rollback: it preserves
operator visibility during WS degradation without changing the tracked
`VITE_DASHBOARD_WS_ONLY=true` default.

## Rollback

### Zero-code rollback (env var)

Comment out (or remove) the `VITE_DASHBOARD_WS_ONLY` line in the env
file for the affected environment, then restart the build / dev
server:

```bash
# Dev
sed -i.bak '/VITE_DASHBOARD_WS_ONLY=true/s/^/# /' dashboard/.env.development
pnpm --filter masc-dashboard dev
```

The dashboard immediately reverts to parallel mode on next page load.
Beacon switches to gray.

### Hot rollback (browser console)

For a single tab without a redeploy, runtime injection beats build-time
flag:

```js
window.__MASC_DASHBOARD_WS_ONLY__ = false
location.reload()
```

The reloaded tab opens authenticated streaming-fetch SSE alongside the WS
socket.
This works because `dashboardWsOnlyEnabled()` checks the runtime
window flag first.

## What this PR does NOT change

- **Server-side SSE publisher infra** stays running.  Dashboard observer SSE is
  served through `GET /mcp?sse_kind=observer`; `Oas_sse_bridge` and the gRPC
  subscriber path remain operational.
  Removing them is a later PR after parallel-mode soak validates the WS
  channel under real workloads.

## Verifying after cutover

1. Open the dashboard.
2. Confirm the beacon is green.
3. DevTools → Network → confirm:
   - 0 steady-state fetches to `/mcp?...sse_kind=observer`
   - 1 connection to `/ws` (WebSocket type, status 101)
4. Trigger a server-side event (e.g., a heartbeat, a keeper
   broadcast).  Beacon counter should increment, journal feed should
   show the event.
5. Watch the beacon for 5 minutes.  Steady green = cutover successful.
   Yellow flickers under known-idle workloads are expected; persistent
   yellow under known-active workloads is a regression signal.
6. Close the WS abnormally or stop the listener. Confirm one authenticated
   `/mcp?...sse_kind=observer` fetch appears, the beacon reports `SSE fallback`,
   and the fetch is aborted after WS becomes ready again.
