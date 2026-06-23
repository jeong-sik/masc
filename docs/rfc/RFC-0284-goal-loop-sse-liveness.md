---
rfc: "0284"
title: "Goal-loop status SSE liveness — server-side change detection extends the goals snapshot"
status: Draft
created: 2026-06-23
updated: 2026-06-23
author: vincent
supersedes: []
superseded_by: null
related: ["0201", "0022", "0113"]
implementation_prs: []
---

# RFC-0284: Goal-loop status SSE liveness

Status: Draft · The goal-loop OODA status is the most live-feeling dashboard
surface but is the only one the frontend reads by HTTP pull; this RFC pushes it
over SSE by extending the existing `goals` snapshot, with the broadcast trigger
on the OCaml server (not the out-of-process worker).

Drafted by: Claude Opus 4.8 (with owner, 2026-06-23) after the HITL/Goal/Task
dashboard surface map. Interim parity gate for the SSE event-type boundary is
PR #22124; full typed-event enforcement is MASC task-1479 (keystone).

> Anchors are read against `origin/main` (`39f0cd076f`) on 2026-06-23.

---

## §1 Problem — the most live surface is pull-only

The goal-loop status (OODA phases observe / orient / decide / act / verify) is
served to the dashboard by HTTP:

- Backend read model: `Dashboard_goal_loop.status_json`
  (`lib/dashboard/dashboard_goal_loop.mli:3`), a 5 s TTL cache
  (`goal_loop_cache_ttl_s = 5.0`) over `<masc_dir>/goal-loop/status.json`
  (`dashboard_goal_loop.ml`), exposed at `GET /api/v1/dashboard/goal-loop/status`.
- Frontend: `goal-loop-panel.ts` fetches on mount via `useEffect` +
  `fetchGoalLoopStatus`, plus a manual refresh button. There is **no SSE
  handler** for goal-loop status (`rg goal.loop dashboard/src/sse-store.ts` = 0).

So the backend re-publishes status continuously (the worker rewrites the file;
the read model's own comment calls it "the most live-feeling of the dashboard
surfaces"), but the dashboard only observes it on mount or manual refresh. The
operator watching the loop sees stale phases until they click refresh. This is a
**liveness gap**, not a correctness bug — the data is fresh server-side, the
push is missing client-side.

Secondary: the `useEffect`-driven fetch violates the project React rule (data
fetch should be push/`useQuery`, not effect-on-mount).

## §2 Boundary — the worker is out-of-process (Python)

The goal-loop worker is **not** an in-process OCaml fiber. It is a set of Python
scripts implementing the OODA loop (`scripts/goal_loop_scheduler.py`,
`scripts/observe_goal_loop_logs.py`, `scripts/orient_goal_loop_logs.py`,
`scripts/decide_goal_loop_findings.py`, `scripts/verify_goal_loop_logs.py`,
`scripts/goal_loop_status.py`, `scripts/goal_loop_anti_stagnation.py`). They run
out-of-band and write `status.json`; the OCaml SSE server only **reads** it.

Consequence: the worker cannot call the in-process `Sse.broadcast`. The
status-file is the boundary between the non-deterministic Python OODA worker and
the deterministic OCaml serving layer. **Therefore the broadcast trigger must
live on the server**, derived from observing the file — not from a worker call.
Any design that asks the worker to emit SSE couples the Python worker to the
OCaml transport and is rejected (§8).

## §3 Design — extend the `goals` snapshot, detect changes server-side

Two parts:

### §3.1 Reuse the existing `goals` snapshot (no new event type)

The dashboard already pushes a `goals` snapshot that the frontend hydrates
without an HTTP fetch: `sse-store.ts` `case 'goals'` hydrates `planning` and
`tree` sub-resources (`hydratePlanningSnapshot` / `hydrateGoalTreeSnapshot`).
Add a third sub-resource `loop` carrying the goal-loop status JSON, mirroring the
existing multi-resource shape. No new SSE event type is introduced, so the
event-type parity gate (PR #22124) is unaffected and the contract surface does
not widen.

### §3.2 Server-side change detection drives the broadcast

The server reads `status.json` through `Dashboard_goal_loop.status_json` (already
cached). Add a server-side change signal: on the existing dashboard broadcast
tick, compute a cheap fingerprint of the current status (content hash, or the
`generated_at` / `loop_iteration` fields the status already carries) and
broadcast a `goals` snapshot with the `loop` field **only when the fingerprint
changed** since the last broadcast. This:

- keeps the worker untouched (it just writes the file),
- emits at most one push per actual status change (no per-tick spam),
- degrades to today's behavior if detection is unavailable (the HTTP pull stays
  as a fallback for first paint and reconnect hydration).

### §3.3 Implementation note — a `goal_loop_status` event type is required (amended 2026-06-23)

§3.1 assumed the `goals` snapshot is already pushed live and that no new event
type would be needed. Grounding the live path against the code showed otherwise:
the dashboard live-update path is the SSE → `dashboard/delta` bridge in
`server_mcp_transport_ws.ml`, which keys deltas by `dashboard_slice_for_sse_type
event_type`. The `goals` slice has **no** entry there, so the `case 'goals'`
handler in `sse-store.ts` only runs on the initial `dashboard/snapshot` burst,
never on a live delta. Reusing `goals` with no event type therefore cannot
deliver live updates.

The implementation threads the needle: a dedicated `goal_loop_status` event type
is broadcast (change-gated) and **bridged onto the existing `goals` slice**
(`dashboard_slice_for_sse_type "goal_loop_status" -> Some "goals"`). The frontend
handles it in `hydrateDashboardSlice`'s event-type switch (a `case`, not an
exact-match `event.type === 'X'` route), so the parity gate (PR #22124) stays
unaffected — its inventory only tracks exact-match routes. This keeps the §3.1
goal (reuse the `goals` slice, no new WS slice, parity gate untouched) while
adding the one event type the live delta bridge actually requires. The `goals`
snapshot still carries the `loop` sub-field for the initial-burst / HTTP path.

## §4 Frontend

- `sse-store.ts` `case 'goals'`: when `record.loop` is present, hydrate it into a
  goal-loop state store (new `hydrateGoalLoopSnapshot`, sibling of
  `hydratePlanningSnapshot`).
- `goal-loop-panel.ts`: subscribe to that store; drop the `useEffect` +
  `fetchGoalLoopStatus` mount fetch (keep the manual refresh button and a single
  first-paint fetch for the case where no snapshot has arrived yet). This aligns
  with the project React rule (push, not effect-on-mount).

## §5 Phasing

- **Phase 1 (server)** — add the `loop` field to the `goals` snapshot payload +
  server-side change detection + gated broadcast. Behind a flag if needed; no FE
  change yet (FE ignores the unknown sub-field). Verify the broadcast fires on
  status change and not otherwise.
- **Phase 2 (frontend)** — hydrate `loop`, switch `goal-loop-panel` to the store,
  remove the `useEffect` fetch.
- **Phase 3 (verify)** — liveness regression test + reconnect hydration.

## §6 Verification

- Server: a test that a status change produces exactly one `goals` snapshot with
  a `loop` field, and an unchanged status produces none (change-detection gate).
- Frontend: a test that a `goals` snapshot carrying `loop` updates the goal-loop
  store without an HTTP fetch (mirrors the existing `project_snapshot`
  no-HTTP-fetch test), and that reconnect re-hydrates.
- Parity gate (PR #22124): unaffected — `goals` is a snapshot sub-kind routed via
  the `case 'goals'` switch, not an exact-match `event.type === 'X'` route, so it
  is outside the gate's exact-match inventory by design.

## §7 Alternatives considered

- **A new `goal_loop_status` exact-match SSE event** — a dedicated exact-match
  `event.type === 'goal_loop_status'` route + handler. Pro: the parity gate would
  auto-enforce it. Con: widens the parity-gated exact-match contract surface.
  Rejected in favor of the §3.3 hybrid: a `goal_loop_status` event type is used
  (the delta bridge requires one) but bridged onto the existing `goals` slice and
  handled in the slice event-type switch, so it is **not** an exact-match route
  and the parity gate is unaffected.
- **Worker → broadcast** — have the Python worker notify the server (HTTP/IPC) to
  broadcast. Rejected (§2): couples the out-of-process worker to the OCaml
  transport; the server already reads the file, so change detection is strictly
  simpler and keeps the boundary clean.
- **Shorten the HTTP poll** — drop the 5 s TTL / poll faster from the FE.
  Rejected: still pull, still `useEffect`, more load, no reconnect story.

## §8 Out of scope

- Full compile-time typed-event enforcement (closed event-type sum + typed
  broadcast API + raw-string ban) — that is the keystone (MASC task-1479,
  RFC-0004 increment); this RFC deliberately stays within the existing snapshot
  mechanism.
- Other pull-only dashboard surfaces — addressed individually if they show the
  same gap.
