---
status: in-progress
last_verified: 2026-04-26
code_refs:
  - dashboard/src/dashboard-ws-cutover.ts
  - dashboard/src/components/transport-beacon.ts
  - dashboard/.env.development
---

# SSE → WebSocket Cutover

> Status: Stage 1 (dev cutover + observability beacon).
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
| Staging | Set `VITE_DASHBOARD_WS_ONLY=true` in the staging build pipeline |
| Production | Set `VITE_DASHBOARD_WS_ONLY=true` in the prod build pipeline (last) |

The flag is build-time.  A redeploy is required to flip it server-side.
For ad-hoc browser overrides, use the runtime injection below.

## Reading the beacon

The transport beacon sits in the header strip next to the connection
status chip.  States:

| Color | Label | Meaning | Action |
|-------|-------|---------|--------|
| Gray | `WS+SSE (legacy)` | Cutover not active in this build | None — this is the safety-net default |
| Green | `WS-only · open · N events / 60s` | Cutover active, socket open, events arriving | None — the transport is healthy |
| Yellow | `WS-only · silent` | Cutover active, socket open, but no event for >30s | Verify the workload is genuinely idle.  If you expect events and the gray-mode beacon would have shown them, consider rolling back |
| Red | `WS-only · disconnected` | Cutover active, but the socket is closed | Wait for auto-reconnect.  If the socket stays closed, roll back |

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

The reloaded tab opens the SSE EventSource alongside the WS socket.
This works because `dashboardWsOnlyEnabled()` checks the runtime
window flag first.

## What this PR does NOT change

- **Server-side SSE infra** stays running.  `/sse`, `/sse/simple`,
  `Oas_sse_bridge`, gRPC subscriber path — all still operational.
  Removing them is a later PR after parallel-mode soak validates the WS
  channel under real workloads.
- **A2A external endpoints** (`/sse/portal`, `/sse/subscriptions`) stay
  unchanged.  External agents that subscribe to those routes are NOT
  affected by the dashboard cutover.

## Verifying after cutover

1. Open the dashboard.
2. Confirm the beacon is green.
3. DevTools → Network → confirm:
   - 0 connections to `/sse` (EventSource type)
   - 1 connection to `/ws` (WebSocket type, status 101)
4. Trigger a server-side event (e.g., a heartbeat, a keeper
   broadcast).  Beacon counter should increment, journal feed should
   show the event.
5. Watch the beacon for 5 minutes.  Steady green = cutover successful.
   Yellow flickers under known-idle workloads are expected; persistent
   yellow under known-active workloads is a regression signal.
