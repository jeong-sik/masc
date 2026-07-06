---
rfc: "0088"
title: "Counter-as-Fix → Result Propagation (umbrella scoping)"
status: Active
created: 2026-05-15
updated: 2026-05-17
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0044", "0062", "0063", "0077"]
implementation_prs: ["15519"]
---

# RFC-0088 — Counter-as-Fix → Result Propagation (umbrella scoping)

## 1. Problem

`instructions/software-development.md §워크어라운드 거부 기준 §1` flags **telemetry-as-fix** as a hard merge-reject signal:

> counter is *alarm* not *fix*. PR makes silent failure *visible* but data loss continues. AI agents inherit the pattern as precedent.

Bug-hunter audit (2026-05-15) on `lib/` enumerated 16+ candidate sites following this shape (`Otel_metric_store.inc_counter Otel_metric_store.metric_silent_* | metric_*_drop | metric_*_failures` paired with `Log.<area>.warn "[silent:...]"` and a default return). On verification (§3) the inventory partitions into four buckets, **three of which are already covered by accepted RFCs or an in-flight Phase B switch**.

This RFC's purpose is **not** to introduce a new pattern. It is to:

1. Make the partitioning explicit so future "another silent counter" PRs are routed to the correct existing RFC instead of spawning a new scope.
2. Identify the only sub-area not yet covered (Workspace async-context-free telemetry drop) and either fold it into RFC-0044 or absorb it here as a §4 extension.
3. Lock the merge-reject bar so the *17th* counter PR cites this RFC instead of being grandfathered.

## 2. Non-goals

- New typed sum types parallel to `Read_drop_reason.t` (RFC-0044) or `Write_failure_reason.t` (RFC-0077). Reuse those.
- Phase B PR-2 Strict flip for `MASC_AUTH_STRICT`. Owned by the auth-strict track (PR #9786 follow-up). This RFC documents the boundary, not the flip.
- Removing already-grandfathered counters. They stay until each migration RFC owns its cohort.
- WAL / append-only journal redesign. Out of scope of all three RFCs (0044, 0077, 0088).

## 3. Verified inventory (2026-05-15)

| # | Site | Counter / log marker | Category | Owning RFC |
|---|------|----------------------|----------|------------|
| 1 | `lib/mcp_server_eio_execute.ml:382-388` | `metric_silent_auth_token_resolve_error` + `[silent:auth_token_resolve_error]` | Auth — Phase B PR-2 flip-switch (dry-run telemetry already paired via Phase A F2 #11257) | **Auth strict track (PR #9786 follow-up)** |
| 2 | `lib/server/server_auth.ml:298-306` | `metric_silent_dashboard_actor_fallback` (outcome=none) + `[silent:dashboard_actor_fallback]` | Auth — Phase B PR-2 flip-switch | Auth strict track |
| 3 | `lib/server/server_auth.ml:340-348` | `metric_silent_dashboard_actor_fallback` (outcome=error) + `[silent:dashboard_actor_fallback]` | Auth — Phase B PR-2 flip-switch | Auth strict track |
| 4 | `lib/workspace.ml:101-105` | `metric_workspace_telemetry_drop` + `warn_telemetry_drop` | Workspace — telemetry emission from non-Eio context. Caller is the failing telemetry path itself; no `Result.t` chain to propagate to. | **Unowned — §4 of this RFC or fold into RFC-0044** |
| 5 | `lib/telemetry_eio.ml:149` | `Safe_ops.report_persistence_read_drop` (typed `Read_drop_reason.t`) | Already-migrated read-side | RFC-0044 (active path) |
| 6 | `lib/telemetry_eio.ml:166-173` | `Safe_ops.report_persistence_read_drop` (typed) | Already-migrated read-side | RFC-0044 (active path) |
| 7 | retired | `[identity_drift:alias_fallback]` WARN-only credential alias fallback | Runtime credential alias fallback removed; old dashboard-dev token files are ignored and the dashboard dev-token route only mints or reuses the canonical dashboard token. | Closed |
| 8 | `lib/dashboard.ml:460-475` | reads `metric_total` to format a *display title* | Aggregation reader, not a counter-as-fix emitter | Out of scope (false positive) |
| 9-12 | retired | The previous `lib/keeper/keeper_alerting.ml` alert writer was removed with the heuristic score/fanout path. | Closed | RFC-0077 (cohort C retired item) |
| 13-15 | `lib/keeper/keeper_checkpoint_store.ml:55, 91, 195, 238, 256` | `Log.Keeper.warn "... failed"` + drop archive | Write-side / cleanup silent failure | RFC-0077 (cohort B) |
| 16+ | `lib/keeper/keeper_heartbeat_loop.ml:195, 462, 1268`, `keeper_keepalive.ml:513`, `keeper_supervisor.ml:720, 2061`, `keeper_turn_runtime_budget.ml:675`, `keeper_agent_memory_episode.ml:103, 192`, `keeper_crash_persistence.ml:135`, `keeper_approval_queue.ml:430`, `keeper_context_core.ml:786` | `Log.Keeper.warn/error "... write/save failed"` + warn + default | Write-side silent failure | RFC-0077 §3.1 (already enumerated in that RFC's inventory) |

### 3.1 Partition summary

| Bucket | Site count (verified) | Disposition |
|--------|-----------------------|-------------|
| Auth Phase B flip-switch | 3 | Defer to auth strict track. RFC-0088 imposes **no new requirement** beyond what Phase A F2 already wired. |
| Already RFC-0044 read-side | 2 (telemetry_eio) | No action. Already migrated. |
| Already RFC-0077 write-side inventory | 13+ (keeper/) | No action. Each is in RFC-0077 §3.1 inventory or cohort B/C scope. |
| Workspace async-context-free drop | 1 counter, 3 emit sites (`workspace.ml:194, 259, 269` → `warn_telemetry_drop`) | Unowned. §4 below. |
| Diagnostic / aggregate-reader false positives | 2 | Excluded from telemetry-as-fix definition. |

The 16+ headcount from the audit dissolves into **3 active counters that have a defined home**, **13+ sites that are already inventoried by RFC-0044 or RFC-0077**, and **1 genuinely unowned area** (Workspace).

## 4. Workspace async-context-free telemetry drop — proposal

`lib/workspace.ml:75-110` (`warn_telemetry_drop`) is invoked from 3 sites (`workspace.ml:194 agent_lifecycle`, `:259 task_transition`, `:269 accountability`) when the caller is outside an Eio context and cannot emit telemetry. The current shape:

```
Log.Misc.warn ... "telemetry/audit dropped (non-Eio context): %s/%s" event_family event_kind;
Telemetry_observe.observe_silent ~kind:"workspace_telemetry_drop_metric" (fun () ->
  Otel_metric_store.inc_counter Otel_metric_store.metric_workspace_telemetry_drop ~labels:[...] ())
```

### 4.1 Why this is not a "telemetry-as-fix" violation in the §1 sense

The *event itself is the telemetry payload*. The "data loss" is loss of a single observability event, not durable state. There is no `Result.t` chain to propagate to — the immediate caller is the lifecycle hook (e.g. `agent_lifecycle`) which is fire-and-forget by design.

### 4.2 What is missing

- **Typing**: `event_family` / `event_kind` are free strings. Same critique as RFC-0044 §3.1's `reason` field. The 3 call sites currently bound the values (`"agent_lifecycle"`, `"task_transition"`, `"accountability"`), but the type does not enforce it.
- **Routing alternative**: a *buffered* in-process channel could absorb the event and replay it inside an Eio domain. This is RFC-scope but has caller-chain implications (e.g. ordering vs. accountability events).

### 4.3 Decision (RFC-0088 §4.3)

**Decided 2026-05-17: Option A. Implemented via PR #15519.**

Two options were considered:

| Option | Outcome | Cost |
|--------|---------|------|
| **A — typed event next to RFC-0044 family** *(chosen)* | Closed sum `Workspace_telemetry_drop_event.t` (`Agent_lifecycle | Task_transition | Accountability`) in `lib/workspace/workspace_telemetry_drop_event.{ml,mli}`. Updates Workspace 3 call sites + `Otel_metric_store.metric_workspace_telemetry_drop` label encoding via `family_to_wire` / `kind_to_wire` / `to_metric_labels`. | Single PR (~80 LoC). Zero behavior change; only label cardinality is now compiler-bounded. |
| **B — buffered replay** *(rejected for now)* | Introduce `lib/workspace/telemetry_buffer.ml` (bounded `Eio.Stream`) + drain fiber in `server_runtime_bootstrap`. Workspace enqueues; drain replays inside Eio. Drop counter retained only as overflow signal. | RFC-scope. Touches bootstrap + ordering invariants. Re-open as a follow-up RFC only if dashboard data shows non-trivial drop volume. |

Implementation note: instead of merging the typed reason *into* RFC-0044's `Read_drop_reason.t` (the original "tentative amendment to RFC-0044" framing in Open question Q2), PR #15519 placed it in a sibling module under `lib/workspace/`. This keeps RFC-0044 focused on persistence read-drops and avoids cross-domain coupling. The Q2 wording in §9 is therefore superseded by what shipped.

## 5. Merge-reject bar consolidation

A PR that adds a new emit site of any of the following without citing an owning RFC and the §3 partition row is rejected:

1. `Otel_metric_store.metric_silent_*` (auth-strict family) → owner = auth-strict track; new emit sites blocked until Phase B PR-2 lands.
2. `Otel_metric_store.metric_persistence_read_drops` → owner = RFC-0044.
3. `Otel_metric_store.metric_keeper_write_meta_failures` (and adjacent write counters) → owner = RFC-0077.
4. `Otel_metric_store.metric_workspace_telemetry_drop` → owner = this RFC §4.

Net-new "silent counter + warn + default" emit site that does **not** fit any of the four families requires:

- A new owning RFC (not this one — this is umbrella scoping), or
- A `WORKAROUND: production-blocking` label + explicit dated `removal target: <RFC-NNNN-merge>` per §워크어라운드 거부 기준 Override clause.

## 6. Stable behavior guarantee

This RFC introduces **zero** behavior change. No code is touched by RFC-0088 merge. §4 Option A becomes a follow-up PR (Workspace typed reason). §5 is enforced by reviewer convention and by `bash ~/me/scripts/pr-rfc-check.sh`.

## 7. Drift guards

- **Inventory pin**: §3 table is the authoritative inventory at 2026-05-15. A new emit site in `git grep "metric_silent_\|metric_workspace_telemetry_drop\|metric_persistence_read_drops"` that is not listed here triggers reviewer action (route to owning RFC or reject).
- **Phase B linkage**: when Phase B PR-2 lands and `Auth_strict_mode.Strict` becomes default, the 3 auth sites in §3 rows 1-3 become `Error` returns. The `metric_silent_*` family then deletes (counter retires with the silent fallback). This RFC's row 1-3 disposition then transitions from "defer" to "retired".

## 8. Trade-offs

| For | Against |
|-----|---------|
| Eliminates the recurring "is X a telemetry-as-fix?" question by partitioning the entire `metric_*_drop / _silent_ / _failures` namespace into owning RFCs. | Adds a fourth RFC to an already busy persistence-typing family (0042 / 0044 / 0062 / 0077). |
| Catches the case where the audit headcount (16+) overstates novel scope — most rows are already owned. | Risk of becoming a *re-routing index* rather than a substantive RFC. Mitigated by §4 (Workspace proposal) being substantive. |
| Locks the merge-reject bar at four explicit counter families. | §5 enforcement is reviewer-side, not type-system-side. RFC-0078 reservation ledger pattern could later add a CI lint for new `metric_silent_*` names. |

## 9. Open questions

- **Q1**: Should `Auth_strict_mode` default flip (Phase B PR-2) be referenced as a *blocker* for this RFC's `Implemented` transition, or independent? **Tentative**: independent — the Phase B switch closes auth rows 1-3, but RFC-0088's scope is the partition + Workspace §4, both of which can reach `Implemented` before Strict default.
- **Q2**: Should §4 Option A consume an RFC-0044 amendment or live here? **Tentative**: amendment to RFC-0044 (`Workspace_telemetry_drop_reason.t` lives next to `Read_drop_reason.t`). RFC-0088 stays as the umbrella partition doc.
- **Q3**: Is there a CI lint that can enforce §5 (new `metric_silent_*` names blocked at PR time)? **Tentative**: yes — analogous to RFC-0078's number-collision workflow. Out of scope for this RFC, candidate follow-up.

## 10. Acceptance

- [x] §3 inventory table reviewed and rows confirmed or contested by maintainer. *(Inventory frozen at 2026-05-15; drift guard in §7 covers ongoing reviewer enforcement.)*
- [x] §4.3 decision A vs B made; **A chosen, implemented via PR #15519** (sibling module under `lib/workspace/`, not an RFC-0044 amendment — see §4.3 implementation note).
- [x] §5 merge-reject bar referenced in `~/me/scripts/pr-rfc-check.sh` subsystem-keyword map (`metric_silent_`, `metric_workspace_telemetry_drop` → owning RFC). *(see ~/me PR for pr-rfc-check expansion)*
- [ ] When Phase B PR-2 Strict default lands, rows 1-3 disposition transitions to "retired" in this RFC (one-line update). *(Tracked separately under the auth-strict track; not a blocker for `Active` status — see §9 Q1.)*

With the first three items closed and the fourth scoped out (`§9 Q1` "independent" verdict), this RFC moves from Draft to **Active** as of 2026-05-17.

## 11. References

- RFC-0042 (Active) — closed sum for keeper turn terminal code; foundational pattern.
- RFC-0044 (Draft) — read-side persistence-drop typed reason.
- RFC-0062 (Active) — typed `Tool_result.t` blocker class.
- RFC-0063 (Draft) — telemetry feedback loop & cooperative scheduling safety.
- RFC-0077 (Draft) — write-side silent failure typed propagation.
- PR #9786 (Merged 2026-04-27) — boot-time credential token uniqueness audit; in-code comments mark Phase B PR-2 as the Strict flip site.
- PR #11257 (Merged 2026-04-27) — Phase A F2 MASC_AUTH_STRICT dry-run telemetry (`[would_reject]` pairing).
- `instructions/software-development.md §워크어라운드 거부 기준` — telemetry-as-fix reject criteria.
- Bug-hunter audit 2026-05-15 — source of the 16-site claim that this RFC partitions.
