# MASC Performance Diagnosis Reality Check — 2026-05-06

Source under review: `/Users/dancer/Downloads/MASC_실전_성능_진단.md`

This audit treats that report as a dated input, not current truth. The report
was written against commit `58ed9c82`; the current inspection target is
`2e04c82c60a1` on `origin/main`.

## Current Truth

Several quick-win recommendations in the report are already implemented or no
longer map cleanly to the current dashboard:

- The dashboard already defaults to WS-only mode. `dashboard/src/dashboard-ws-cutover.ts:11`
  through `dashboard/src/dashboard-ws-cutover.ts:31` sets WS-only to `true`
  unless runtime or build config opts out.
- The app already primes the lightweight shell before heavier projections.
  `dashboard/src/app.ts:114` through `dashboard/src/app.ts:121` calls
  `refreshShell({ light: true })`, namespace truth refresh, and dashboard config
  fetch without blocking the full app mount.
- The server dashboard shell summary already requests lightweight keeper rows.
  `lib/server/server_dashboard_http_core.ml:304` through
  `lib/server/server_dashboard_http_core.ml:310` calls
  `Operator_control.snapshot_json` with `~view:"summary"` and
  `~lightweight_summary:true`.
- WS inbound parsing already has a browser Web Worker path.
  `dashboard/src/dashboard-ws.ts:56` through `dashboard/src/dashboard-ws.ts:83`
  initializes the parser worker, and `dashboard/src/dashboard-ws.ts:409`
  through `dashboard/src/dashboard-ws.ts:424` uses it when available.

The user-provided live log still shows `keepers_json` rows taking roughly
1.8s to 3.0s during startup/operator refresh. That points at the current
server-side snapshot path, not only the stale frontend/SSE items from the
dated report.

## Implemented Slice

The current compact keeper row used to call the full runtime-trust snapshot:

- `lib/operator/operator_control_snapshot.ml:516` now calls
  `Keeper_runtime_trust_snapshot.summary_json` instead of
  `Keeper_runtime_trust_snapshot.snapshot_json`.
- `lib/keeper/keeper_runtime_trust_snapshot.ml:824` through
  `lib/keeper/keeper_runtime_trust_snapshot.ml:887` adds a summary builder
  that keeps the compact dashboard fields but avoids full causal/audit timeline
  construction.
- The full path still exists for detailed views. It reads recent tool calls,
  approval audit, transition audit, pending approvals, and runtime contract
  data in `lib/keeper/keeper_runtime_trust_snapshot.ml:889` through
  `lib/keeper/keeper_runtime_trust_snapshot.ml:1019`.
- `lib/operator/operator_control_snapshot.ml:580` through
  `lib/operator/operator_control_snapshot.ml:595` now logs a `trust=...ms`
  sub-op so future live runs can prove whether this path is still material.

This is intentionally surgical: compact dashboard rows still expose
`disposition`, `needs_attention`, `next_human_action`, execution summary,
latest terminal reason, latest next action, and latest causal event. They no
longer pay for every detailed runtime-trust timeline read on each lightweight
summary refresh.

## Stale Or Needs Fresh Evidence

- "Remove SSE duplication" is stale for the default route because WS-only mode
  is already default.
- "Move JSON/SSE parsing to Web Worker" is stale for browsers that support
  Worker because the parser worker path already exists.
- "Enable browser perMessageDeflate" is not implemented here. The current
  browser WebSocket client does not expose a normal per-connection compression
  option in the application code path; server/browser compression policy needs
  current browser and server docs before changing runtime behavior.
- gRPC-Web/protobuf, Redis caching, Saturn, io_uring, zstd wire changes, and
  provider pricing/model claims are all time-sensitive or architecture-wide.
  They require separate current evidence and operator impact review before code
  changes.

## Next Measurement

Run a live dashboard shell refresh against the patched binary and compare:

```sh
scripts/dune-local.sh build test/test_operator_control.exe
./_build/default/test/test_operator_control.exe
./start-masc-mcp.sh --base-path ~/me
```

Then inspect dashboard logs for `keepers_json:* trust=...ms` and total
`snapshot_json` time. If total time remains high while `trust` is low, the next
slice should focus on `meta`, `profile`, and `agent` sub-ops from the same log
line rather than revisiting stale frontend claims.
