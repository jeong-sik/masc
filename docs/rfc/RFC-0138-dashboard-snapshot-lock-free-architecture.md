# RFC-0138 — Dashboard Snapshot: Lock-Free Immutable Architecture (Phase 3 Root Fix)

**Status**: Phase 3 in progress (Steps 1-3 merged; Steps 4-5 Draft PR)
**Author**: Vincent / Claude Opus 4.7
**Date**: 2026-05-19 (last updated 2026-05-20)
**Supersedes**: N/A
**Related**:
- Report: `vfile:///Users/dancer/me/.worktrees/dashboard-slow-endpoints-report-20260519/memory/masc-mcp-dashboard-slow-endpoints-report-2026-05-19.html` (jeong-sik/me#1144)
- Phase 1 PR #16645 (Server-Timing header) — **merged**
- Phase 1 PR #16654 (cache-stats endpoint) — **merged**
- Phase 2 PR #16656 (/tools 30s cache) — Draft
- Phase 2 PR #16660 (/telemetry 1s cache) — Draft
- Phase 2 PR #16664 (frontend exponential backoff) — Draft

## 1. Problem (Symptom Surface)

5 dashboard endpoints (`/shell`, `/tools`, `/project-snapshot`, `/telemetry`, `/telemetry/summary`) showed 30 s pending in DevTools (3 timed out). The report identified four contributing scenarios:

- Cold start + 5 concurrent requests
- `Dashboard_cache` lock contention + `namespace_truth_shell_refreshing` atomic CAS
- Frontend 3 s polling × backend stall = retry storm
- Disk I/O contention on per-keeper directory scan

## 2. Why Phase 2 Is Mitigation, Not Root Fix

Phase 2 (PRs #16656/#16660/#16664) added caches and frontend backoff. These reduce the *frequency* of slow paths but do not remove the cause:

| Phase 2 mechanism | Underlying problem it does **not** fix |
|---|---|
| 30 s `/tools` cache | Synchronous compute path still exists for every cache miss + cold start |
| 1 s `/telemetry` cache | Synchronous compute path remains for every cache miss + cold start |
| Frontend exponential backoff | Smooths client load but server still blocks the compute thread on cache miss |
| `Dashboard_cache.get_or_compute_with_timeout` | The timeout itself is a symptom — the report counted **14+ MASC_* timeout env variables** (sw-dev §Symptom 억제 §1) accumulated to make blocking compute survivable. The root is that the HTTP path is allowed to block at all. |

Adding more caches and more timeout env vars is the [sw-dev §워크어라운드 거부 §1 — Cap/Cooldown self-fulfilling spiral](../../../me/instructions/software-development.md). The instrumentation from Phase 1 made this visible.

## 3. Root Fix Proposal

**HTTP read handlers must never block on compute.** The compute path is moved to a single background fiber that publishes a fresh `Dashboard_snapshot.t` into an `Atomic.t` slot on a steady interval. Read handlers `Atomic.get` the slot and project the requested fields — wait-free, branch-free, no timeout.

### 3.1 Why Atomic.t is the right shape

OCaml 5 has compiler/runtime guarantees that an `Atomic.t` cell holding an immutable value is read by `Atomic.get` in nanoseconds with no lock acquisition. A struct value containing JSON sub-trees is shared by reference and never mutated post-publish. This pattern is well-established (Folly's `ReadMostlyShared`, Java's `AtomicReference<ImmutableSnapshot>`).

The contention path in the current code (`namespace_truth_shell_refreshing` CAS + `Dashboard_cache` per-key Eio.Mutex + waiter poll loop) exists only because the HTTP path *does* the compute. Once the compute moves to a single owner, none of those primitives are needed.

### 3.2 Phase 3 module surface (initial sketch)

```ocaml
(* lib/dashboard/dashboard_snapshot.mli *)

type t = private {
  generated_at : float;          (* Unix.gettimeofday at publish *)
  generation : int;              (* monotonically increasing per publish *)
  shell : Yojson.Safe.t;
  tools : Yojson.Safe.t;
  namespace_truth : Yojson.Safe.t;
  telemetry_summary : Yojson.Safe.t;
}

val current : unit -> t option
(** Atomic.get from the live slot. Returns [None] before the first
    successful publish.  Wait-free; never blocks. *)

val current_or_bootstrap : config:Coord.config -> t
(** [current ()] if populated; otherwise the bootstrap value computed
    once at server start.  Still wait-free in steady state. *)

val refresh_loop :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Coord.config ->
  interval_sec:float ->
  unit
(** Background fiber: every [interval_sec], recompute a fresh [t] and
    publish via [Atomic.set].  Failure to compute keeps the previous
    snapshot live (no "timeout JSON" leakage to clients).  Cancellation
    via the switch. *)

val publish_for_test : t -> unit
(** Test-only injection.  Never wired to a production path. *)
```

### 3.3 Migration sequence (do NOT batch)

| Step | PR scope | Confidence required to proceed | Status (2026-05-20) |
|---|---|---|---|
| **0. This RFC + prototype** | RFC-0138 + `Dashboard_snapshot` module + harness tests | Required before any handler wire | merged (prereq) |
| **1. Wire /shell as read-only snapshot getter** | Replace `dashboard_shell_http_json` cache path with `Dashboard_snapshot.current_or_bootstrap` for the read; keep `Dashboard_cache` as fallback for one sprint | Must show Server-Timing `cache_lookup;dur~0ms` p99 for /shell | **MERGED** via PR #16694 |
| **2. Wire /tools and /telemetry/summary** | Same pattern. /telemetry (query-keyed) stays cache-based as it is per-query. | p99 < 5ms on both warm | **MERGED** via PR #16730. Incidental: latent paren regression at `server_dashboard_shell_snapshot.ml` line ~76 was undetected by sandbox CI (see `reference_masc_mcp_ci_build_test_skips`); bundled hotfix carried into Step 4 / Step 5 PRs |
| **3. Wire /project-snapshot** | Highest-risk migration — uses Eio fiber timeouts. Move the fiber-with-timeout pattern to the refresh fiber, not the HTTP path. | All 6 timeout env vars (`MASC_NAMESPACE_TRUTH_*`) become dead code | **MERGED** via PR #16738 (also wires `/namespace-truth` and `/room-truth` aliases) |
| **4. Retire 4 `MASC_NAMESPACE_TRUTH_*_TIMEOUT_S` env knobs** | Remove env reads on the namespace-truth read path; emit one-shot WARN at server start if any are still set. | Originally gated on "Server-Timing `snapshot_read;dur~0ms` p99 on retired paths"; **per user override, advanced on code-fact (Step 3 wire merge) instead of p99 measurement**. | **Draft PR #16752** (build-passing). Caveat: `MASC_DASHBOARD_EXECUTION_REFRESH_TIMEOUT_S` is **not** retired — it has a live consumer at `server_dashboard_http_execution_surfaces.ml:572` (proactive refresh loop); only its fallback-path lookup at `namespace_truth:100` was retired |
| **5. Retire `Dashboard_cache` from read path + rename `Server_dashboard_shell_snapshot` → `Server_dashboard_snapshot_select`** | Cache module remains for query-keyed `/telemetry` only; module rename reflects post-Step 3 role (multi-endpoint select projection). | Hit ratio data from `/cache-stats` (#16654) shows no other dependencies | **Draft PR #16761** (build-passing). Fallback function `dashboard_namespace_truth_http_json` remains alive as cold-start safety net; its deletion is deferred to a future RFC gated on cold-start snapshot-hit observability |

### 3.4 Phase 3 closeout notes (2026-05-20)

- Steps 1-3 wired all five read endpoints (`/shell`, `/tools`, `/telemetry/summary`, `/project-snapshot`, `/namespace-truth` + `/room-truth` aliases) to `Dashboard_snapshot.current_or_bootstrap` and merged in three sequential PRs (#16694, #16730, #16738).
- Step 4 (env-knob retirement) was advanced before the originally specified p99 measurement gate. The retire criterion in the table above was relaxed per user override: progression is keyed on the Step 3 wire merge (code-fact) rather than measured p99 latency on retired paths. Outstanding measurement work tracked separately.
- Step 4 scope was narrowed at execution time: only the four `MASC_NAMESPACE_TRUTH_*_TIMEOUT_S` knobs are retired. `MASC_DASHBOARD_EXECUTION_REFRESH_TIMEOUT_S` is retained — it is read by a live proactive refresh loop (`server_dashboard_http_execution_surfaces.ml:572`), not just by fallback lookup.
- Step 5 retires `Dashboard_cache` from the read path and renames `Server_dashboard_shell_snapshot` → `Server_dashboard_snapshot_select` (the module now serves multiple endpoints, not just `/shell`). The fallback function `dashboard_namespace_truth_http_json` remains alive as a cold-start safety net; deletion is gated on a future RFC for cold-start snapshot-hit observability.
- Step 2's incidental paren regression at `server_dashboard_shell_snapshot.ml` line ~76 went undetected by sandbox CI. The skip vector is tracked in memory file `reference_masc_mcp_ci_build_test_skips` and is a candidate for future CI remediation. The hotfix is carried inside the Step 4 and Step 5 PRs.
- §4 trade-off claim "1 (`refresh_interval_sec`)" for tunable env vars is now closer to reality after Step 4 lands. §7 acceptance criteria items remain open pending the deferred p99 measurement pass.

## 4. Trade-offs

| | Snapshot Architecture (proposed) | Status Quo (cache + timeouts) |
|---|---|---|
| **Read latency p99** | < 1 ms (Atomic.get + json projection) | 30 s+ on contention |
| **Compute frequency** | Every 5 s, one fiber | Every cache miss × N clients |
| **Failure mode** | Stale snapshot (auditable: `generated_at`) | Empty JSON, timeout JSON, fallback chain, lock-wait queue |
| **Tunable env vars** | 1 (`refresh_interval_sec`) | 14+ accumulated |
| **Code surface** | New module + refresh fiber | `Dashboard_cache` 583 LoC + `namespace_truth` 341 LoC + per-handler timeout logic |
| **Read concurrency** | Wait-free (any number of readers) | Bounded by per-key Eio.Mutex serialisation |

### Risks

1. **Stale data window**: 5 s freshness budget. For dashboard read traffic this is acceptable — frontend already polls at 3 s, so worst-case staleness is 5 s + 3 s + RTT. Critical alerts route through a separate streaming surface (`/api/v1/dashboard/stream`) which is unaffected.
2. **Refresh fiber crash**: One fiber's failure stops all updates. Mitigation: `Eio.Switch` supervisor restarts on `Some _exn` other than `Cancelled`, with backoff. Tested via `BugAction` (sw-dev §TLA+ Bug Model).
3. **First-request latency**: Until first publish, `current_or_bootstrap` does a one-shot compute. Identical to current cold-start cost; not worse.
4. **Memory**: Each snapshot holds the previous payload's JSON until GC. With 5 s interval and ~30 KB payload, peak is ~60 KB. Negligible.

## 5. Workaround Rejection Bar Self-Check

- [x] §1 텔레메트리-as-fix: **not violated**. This *removes* counters by removing the failures they measure (cache timeout, fallback chain).
- [x] §2 string 분류기: not used.
- [x] §3 N-of-M: This RFC sequences a deliberate migration. Step 5 retires `Dashboard_cache` for read paths so the workaround stack doesn't survive.
- [x] catch-all `_ ->` 추가: none.
- [x] cap/cooldown/dedup: explicitly removes 14+ existing caps.
- [x] test backdoor: `publish_for_test` is marked test-only; not on any production code path.

## 6. Open Questions

1. **Should `Dashboard_snapshot.t` hold raw OCaml records or JSON?** JSON is simpler to wire (handlers just need a field projection). Records would allow type-safe projection but require duplicating `Telemetry_unified.unified_result` etc. into snapshot-local types. Initial choice: **JSON** for projection simplicity; revisit if profiling shows JSON serialisation dominates the refresh fiber budget.
2. **Refresh interval default?** Frontend polls at 3 s; refresh interval should be ≤ polling. Initial proposal: **2 s** so most polls hit a snapshot at most 2 s stale.
3. **Per-actor scope?** `/tools` cache is per-actor. Snapshot is shared. Initial decision: snapshot publishes the *full* tool inventory; per-actor filtering happens at projection time (cheap, no I/O). Permission check stays at route level.

## 7. Acceptance Criteria

Phase 3 is *complete* when:

- [ ] All 5 endpoints' p99 latency under sustained load < 50 ms (warm) / < 200 ms (cold start, first publish only)
- [ ] All 14 timeout env variables enumerated in §4 marked deprecated with a sunset date
- [ ] `/api/v1/dashboard/cache-stats` (#16654) shows zero entries for `shell:*` / `tools:*` / `namespace-truth:*` keys (cache no longer touched for these read paths)
- [ ] TLA+ `BugAction` for "refresh fiber crash" mirrors live behaviour: invariant `SnapshotEventuallyFresh` violated on crash, restored by supervisor restart
- [ ] Existing `Server_timing` instrumentation surfaces `cache_lookup` ≈ 0 ms for `/shell`, `/tools`, `/namespace-truth` warm path

## 8. Out of Scope (Future RFCs)

- **Streaming surface (Server-Sent Events / WebSocket)** — fundamental UI/UX change. Snapshot architecture is a prerequisite (single source of truth) but the streaming protocol design is a separate RFC.
- **Permission-aware snapshot partitioning** — only needed if /tools per-actor inventory diverges in a way that filtering at projection is too costly. Current evidence: not the case.
- **Cross-process snapshot sharing (multi-replica)** — single-process is enough at current scale.

## 9. References

- Report `vfile:///Users/dancer/me/.worktrees/dashboard-slow-endpoints-report-20260519/memory/masc-mcp-dashboard-slow-endpoints-report-2026-05-19.html` §6 Phase 3 / §7 Action 8 (LoC estimate +280/-120 for prototype) / §4 timeout env inventory
- sw-dev §AI 안티패턴 §2 (Unknown → Permissive Default), §워크어라운드 거부 §1 (Cap/Cooldown spiral)
- OCaml 5 `Atomic` module — https://ocaml.org/manual/5.4/api/Atomic.html
- Eio `Switch.run` + `Switch.on_release` lifecycle — https://ocaml.org/p/eio/latest/doc/Eio/Switch/index.html
