# RFC-0029 — Dashboard Fiber-Batched Aggregation

- **Status**: Draft
- **Author**: yousleepwhen (vincent)
- **Created**: 2026-05-05
- **Audit reference**: `docs/audit-responses/2026-05-05-integrated-improvement-design.md` §1-2, §3-3-C
- **Related**: RFC-0026 (work-conserving keeper admission), RFC-0027 (typed cascade), `lib/dashboard/`

## 1. Problem

The dashboard `snapshot_json` builders fan out a fixed set of sub-ops
(meta, agent, ka, audit, profile, phase, activity, …) per keeper. Today
the fan-out is sequential per keeper inside each fan-out site —
`dashboard_mission.ml:588`, `dashboard_mission.ml:745`,
`dashboard_execution.ml:433`, `dashboard_mission_briefing.ml:127` — so
the wall-clock cost is approximately `K × S × t_subop`, where `K` is the
keeper count and `S` is the sub-op count.

The audit `INTEGRATED_IMPROVEMENT_DESIGN.md` §1-2 reports
`snapshot_json total: 3.3s` at 14 keepers and projects `~8.5s` at 36
keepers. Source/condition for the 3.3s number is unspecified, so this
RFC is **measurement-first**: ship the histogram first, validate the
shape, then commit to the fix.

Two concrete defects to verify:

1. **Sequential per-keeper fan-out.** Each fan-out site iterates
   `keepers` and calls `Dashboard_mission_assembly.*` lookups inline,
   without an Eio fiber group. Eio scheduling is single-threaded but
   non-blocking sub-ops (in-memory projection lookups) finish in
   sub-millisecond — so today's cost is dominated by the *blocking*
   sub-ops (model adapter health probes, OAS roundtrips) which the
   serial walk forces into a chain.

2. **No per-site latency budget.** None of the four fan-out sites emits
   a structured timing record. Operators see only the synthesised
   `snapshot_json` size and HTTP TTFB. We can't tell whether 2.5s of
   the 3.3s came from one sub-op or fifty.

The audit also proposes a `Sqlite3.exec` batch query as the fix. That
is a stack mismatch — the dashboard layer has no SQL backend; keeper
telemetry flows through `Dashboard_mission_assembly` /
`Mission_projection` in-memory aggregations. The right shape is
**fiber-batched aggregation**, not SQL.

## 2. Goal

Replace the sequential per-keeper fan-out at the four sites with an
**Eio fiber group** that issues all keeper sub-ops in parallel and
joins their results at the boundary. Add a structured per-site
histogram so the next audit can argue from data rather than a single
unsourced number.

## 3. Non-goals

- Introducing a SQL backend or any persistent store under the
  dashboard. The right unit of caching is the in-memory projection,
  not a query layer.
- Replacing `Mission_projection` with a streaming pipeline. The
  projection is already an aggregation contract; the change here is
  *how* the dashboard pulls from it.
- Reorganising the `Dashboard_mission_assembly` API. The fan-out
  change is at the call sites, not the assembler.
- Per-keeper caching. The projection rebuild cycle is the SSOT for
  cache invalidation; layering a second cache on top of it would
  re-introduce the staleness pattern that motivated the projection in
  the first place.

## 4. Design

### 4.1 Measurement first (PR-A)

Add `Dashboard_metrics.observe_snapshot_site` — a single histogram with
labels `(site, sub_op_count, keeper_count)`. Wire each of the four
fan-out sites to record the wall-clock between fan-out start and join.

```
val Dashboard_metrics.observe_snapshot_site
  : site:string
  -> sub_op_count:int
  -> keeper_count:int
  -> elapsed_seconds:float
  -> unit
```

Histogram buckets: `[0.05; 0.1; 0.25; 0.5; 1.0; 2.0; 5.0; 10.0]`. The
top bucket needs to be high enough to detect the audit's 3.3s claim
and the projected 8.5s.

This PR ships *only* the histogram. We let it run for a week of normal
keeper traffic before deciding whether the fan-out shape change is
needed at all — if median is sub-second across all four sites, the
audit's framing was wrong and §4.2 / §4.3 don't ship.

### 4.2 Fiber-batched fan-out (PR-B, gated on §4.1 evidence)

Each fan-out site replaces

```ocaml
List.map (fun keeper ->
  let meta = collect_meta keeper in
  let agent = collect_agent keeper in
  let ka = collect_ka keeper in
  ...
  build_keeper_json keeper meta agent ka ...
) keepers
```

with

```ocaml
Eio.Fiber.List.map
  ~max_fibers:max_concurrent_subops
  (fun keeper ->
    Eio.Switch.run (fun sw ->
      let meta_p = Eio.Fiber.fork_promise ~sw (fun () -> collect_meta keeper) in
      let agent_p = Eio.Fiber.fork_promise ~sw (fun () -> collect_agent keeper) in
      let ka_p = Eio.Fiber.fork_promise ~sw (fun () -> collect_ka keeper) in
      ...
      build_keeper_json keeper
        (Eio.Promise.await_exn meta_p)
        (Eio.Promise.await_exn agent_p)
        (Eio.Promise.await_exn ka_p)
        ...))
  keepers
```

`max_fibers` defaults to `keeper_count × sub_op_count` (no artificial
cap; Eio fiber spawn cost is sub-microsecond). Operator can override
via `MASC_DASHBOARD_FAN_OUT_MAX_FIBERS` if a future profile shows the
scheduler thrashing.

`fork_promise` (not bare `fork`) is required — the dashboard runs under
a request switch and we need the per-fiber result back at the join
point. `await_exn` propagates failures so a single broken sub-op
fails the entire snapshot; this is intentional and matches today's
sequential failure model.

### 4.3 Cancellation propagation (PR-B continued)

The dashboard request switch must cancel in-flight sub-op fibers when
the HTTP client disconnects. Today the sequential walk inherits this
naturally because each sub-op is called inline. With the fiber group,
we must wire the request `Switch.t` through to the fan-out site so the
group cancels with the request — `Eio.Switch.run` inside the
`List.map` body achieves this when the parent switch is the request
switch.

Memory cross-ref: `feedback_periodic_scanner_must_transition_state_after_acting`
warned us about half-cancelled scanners. The fiber group must propagate
`Eio.Cancel.Cancelled` upward, never swallow.

## 5. Tests

### 5.1 PR-A (measurement)

- `test_dashboard_metrics_snapshot_site_recorded`: call each fan-out
  site under a fixture switch, assert `observe_snapshot_site` was
  called once per site with `sub_op_count` matching the static count.
- Histogram bucket sanity: synthetic 0.05 → 0.1 bucket; 5.0 → 10.0
  bucket; 100.0 → +Inf overflow.

### 5.2 PR-B (fan-out)

- `test_fiber_fan_out_completes_with_n_keepers_and_s_subops`:
  parameterise over `(K, S)` pairs `(1,1), (5,3), (14,7), (36,7)`.
  Mock `collect_*` to take a fixed 50ms each. Assert wall clock is
  `~max(K × 50ms / max_fibers, 50ms)` not `K × S × 50ms`.
- `test_fiber_fan_out_propagates_cancellation`: cancel parent switch
  mid-fan-out; assert all fibers exit with `Cancelled` and no result
  is partially built.
- `test_fiber_fan_out_propagates_subop_failure`: one sub-op raises;
  assert the join raises `Failure` and other fibers cancel cleanly.

## 6. Performance

- Fiber spawn cost on M3 Max (`Eio_main` on ocaml 5.4): empirically
  sub-microsecond per fiber, so `K × S = 36 × 7 = 252` fibers per
  snapshot is well under the scheduler's per-second throughput.
- Memory: each fiber promise is ~64 bytes; `252 × 64 = ~16 KB` peak
  per snapshot, dropped at switch close.
- Latency: assuming one slow sub-op dominates (50–200ms model probe),
  fan-out reduces wall clock from `K × t_slow` to `t_slow` — a `K×`
  speedup at the bound. 36-keeper / 200ms slow sub-op: 7.2s → 0.2s.
- The `MASC_DASHBOARD_FAN_OUT_MAX_FIBERS` override exists for the
  pathological case where Eio scheduler contention dominates (not
  observed in practice but cheap insurance).

## 7. Migration

- PR-A (this RFC + the histogram instrumentation described in §4.1)
  ships first as a single PR. Runs for one week minimum to populate
  buckets. Acceptance gate: at least one site shows p95 > 1s in
  production telemetry. If no site exceeds the threshold, PR-B is
  **dropped** as YAGNI.
- PR-B (fiber-batched fan-out, §4.2 + §4.3) ships per fan-out site,
  one site per PR (four total). Each site PR includes a regression
  test that the output JSON is byte-identical to the pre-fan-out
  version on a fixed fixture.

No data migration. No keeper restart. The fan-out change is internal
to the dashboard request handler.

## 8. Open questions

- **Should `max_fibers` be tied to keeper count or sub-op count?**
  Current proposal: `keeper_count × sub_op_count` with override. If
  PR-A telemetry shows scheduler thrash at high keeper counts, switch
  to `min(keeper_count, M)` with `M=64`. Re-open after evidence.
- **Should we fail-fast on first sub-op error or join all?**
  Current proposal: fail-fast (matches today's sequential model). The
  alternative — partial JSON with per-keeper error markers — costs
  schema complexity. Re-open if operators want degraded snapshots.
- **Cache projection at fan-out site?** No. The projection rebuild
  cycle is the SSOT and a second cache layer would re-introduce the
  staleness pattern Mission_projection was designed to remove.

## 9. Decision log

- Audit proposed SQL batch query — rejected (stack mismatch). Note
  added at `dashboard_http_keeper_metrics.ml` header (PR #13110).
- Measurement-first sequencing — chosen because the audit's 3.3s
  number has no recorded source. We refuse to redesign on hearsay.
