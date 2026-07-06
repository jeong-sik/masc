---
rfc: "0077"
title: "Write-side silent failure — typed propagation"
status: Implemented
created: 2026-05-14
updated: 2026-05-22
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0044", "0062", "0063", "0071"]
implementation_prs: [15054]
---

# RFC-0077 — Write-side silent failure: typed propagation

(Originally drafted as RFC-0073; renumbered to 0077 on 2026-05-14 after
detecting collision with #15064 RFC-0073~0076 tool readiness package
that reserved 0073-0076 in the same window.)

Status: Draft
Author: jeong-sik (vincent)
Date: 2026-05-14
Supersedes: —
Related: RFC-0044 (read-side counterpart), RFC-0042 (closed sum for keeper terminal code), RFC-0062 (typed `Tool_result.t`), RFC-0063 (telemetry feedback loop), RFC-0071 (exhaustive match sweep)

## 1. Problem

RFC-0044 (Draft) closes the **read-side** telemetry-as-fix pattern: 12 PRs that catch read exceptions, increment a legacy metrics backend counter with a free-string `reason`, and return a default to the caller. RFC-0044 §2 explicitly defers the **write-side** redesign: *"Append-only persistence / WAL... A genuine recovery story for these surfaces requires write-side redesign... Scope is out of this RFC and tracked separately."*

This RFC is that tracked-separately work.

A fresh audit (2026-05-14) of `lib/keeper/` finds 20 write/create call sites that follow the same anti-shape as the read side, but worse: the *write* is the durable contract, not the *read*. When a write fails silently, the next read returns stale or partial state and the caller cannot tell the difference between "no record" and "write was attempted and lost."

Representative sites (full list in §3.1):

```
keeper_heartbeat_loop.ml:462   write_meta failed (message cursor update) -> warn + return stale meta
keeper_heartbeat_loop.ml:195   write_meta failed (heartbeat)             -> warn + return stale meta
keeper_keepalive.ml:513        write_meta failed (bootstrap)             -> warn + continue
keeper_supervisor.ml:720       supervisor presence sync write_meta       -> warn + continue
keeper_supervisor.ml:2061      auto-resume meta write failed             -> warn + skip resume
keeper_turn_runtime_budget.ml:675  overflow pause write_meta failed      -> warn + continue
keeper_agent_memory_episode.ml:103 episode_create failed                 -> error log + None
keeper_agent_memory_episode.ml:192 failed_turn_episode_create failed     -> error log + None
keeper_checkpoint_store.ml:279     OAS snapshot archive write failed     -> warn + drop archive
keeper_crash_persistence.ml:135    crash persistence write failed        -> warn + lose crash record
keeper_approval_queue.ml:430       upsert_rule: save failed              -> warn + in-memory only
keeper_context_core.ml:786         migrate_session_history_logs save     -> error + partial migration
keeper_heartbeat_loop.ml:1268      heartbeat snapshot write failed       -> error + skip snapshot
```

Each site shares three properties:

1. The write returns a `result` or raises an exception **from the IO layer**.
2. The caller catches it, logs `Log.Keeper.warn` or `Log.Keeper.error`, and **does not propagate the failure** to its own caller.
3. The caller's caller cannot distinguish "write ok" from "write failed, state diverged."

A counter-example exists 1500 lines away in the same subsystem:

```
keeper_goal_repair.ml:95   write_meta failed -> Error (Printf.sprintf ...) propagated as Result
```

So the typed-propagation pattern is *known* and *used*, just not consistently. AI agents adding new persistence surfaces inherit whichever shape they see first.

This is the **silent-write** variant of telemetry-as-fix that `instructions/software-development.md §워크어라운드 거부 기준 #1` rejects. Each new site quietly normalizes the pattern. The 20 already in `main` predate this RFC and are grandfathered; the 21st site needs an RFC reason to merge.

## 2. Non-goals

- **Removing existing counters.** Where legacy metrics backend counters already exist for write failures (e.g., `metric_keeper_write_meta_failures`, `metric_keeper_episode_create_failures`), this RFC does not remove them. Counter + typed result coexist until each caller chain migrates.
- **Append-only journal / WAL.** A true recovery story for `write_meta` requires a journal (commit-then-emit, version-tagged records). Out of scope. This RFC restricts to **typing the failure visibility surface** so that `21st-site` PRs can be rejected with `RFC-0077 §X`.
- **Migrating all 20 sites in one PR.** Migration is per-call-chain. PR-1 introduces the typed module; subsequent PRs migrate one chain at a time.
- **Read-side surfaces.** Covered by RFC-0044. Sites that mix read+write (e.g., `keeper_context_core.ml:1456, 1484` checkpoint read error-discarded) belong to RFC-0044.

## 3. Design

### 3.1 Closed-sum `Write_failure_reason.t`

New module `lib/core/write_failure_reason.ml` (and `.mli`), mirroring RFC-0044 §3.1:

```ocaml
type t =
  | Meta_cas_conflict       (** write_meta CAS lost the race; caller's meta is stale *)
  | Meta_io_error           (** filesystem / serialization error *)
  | Append_io_error         (** JSONL append failed *)
  | Snapshot_archive_error  (** checkpoint / snapshot archive write failed *)
  | Episode_create_error    (** external memory create rejected *)
  | Approval_persist_error  (** approval rule durability lost *)
  | Migration_partial       (** multi-record migration partially succeeded *)
  | Crash_capture_lost      (** crash-persistence write failed; record is gone *)
  | Other of string
        (** Escape hatch. PR introducing a new [Other] payload must
            justify why the value cannot be promoted to a constructor.
            Linter (§5) flags PRs that add [Other] for a value already
            used at >= 2 sites. *)

val to_wire : t -> string
val of_wire : string -> t option
```

`to_wire` produces stable legacy metrics backend label strings; existing label conventions for sites that already report a counter are preserved.

### 3.2 Result-based write helper

`lib/core/safe_ops.ml` gains:

```ocaml
type ('ok, 'a) write_outcome =
  | Write_ok of 'ok
  | Write_drop of { reason : Write_failure_reason.t; surface : string; detail : string }
```

Existing helpers (`write_json_atomic`, `write_meta`, `append_jsonl_line`) gain `_result` variants returning `write_outcome`. Migrating callers from `warn + return default` to `Write_ok / Write_drop` is an opt-in mechanical refactor; the counter is emitted by the caller from the typed value (same pattern as RFC-0044 §3.2).

### 3.3 Migration plan

| PR | Scope | Notes |
|----|-------|-------|
| PR-1 | Introduce `Write_failure_reason.t` + `write_outcome` modules. Inert. | Mirrors RFC-0044 PR-1 / RFC-0042 PR-1. No callsite change. |
| PR-2 | Migrate **cohort A: `write_meta` chains** — 10 sites in `keeper_heartbeat_loop.ml`, `keeper_keepalive.ml`, `keeper_supervisor.ml`, `keeper_turn*.ml`. | Highest blast radius. Propagate `Write_drop` to the cycle return so heartbeat can decide to retry. |
| PR-3 | Migrate **cohort B: external memory & checkpoint** — `keeper_agent_memory_episode.ml`, `keeper_checkpoint_store.ml`, `keeper_crash_persistence.ml`. | Cross-module. Episode caller chain needs explicit "create failed, abort vs continue with partial memory" decision. |
| PR-4 | Migrate **cohort C: append-only logs & policy** — `keeper_approval_queue.ml`. | Lower blast radius (policy state). The previous `keeper_alerting.ml` alert writer is retired. |
| PR-5 (optional) | Migrate **cohort D: migration writes** — `keeper_context_core.ml:786, 798`. | Migration is one-time; PR-5 captures the *partial migration* state in `Migration_partial` so an operator can resume. |

PR-2 is the load-bearing migration: it changes 10 sites, all of which are on the keeper heartbeat / supervisor hot path. Per AGENT-LLM-A.md "확인 후 실행 Protocol" — each PR-2 sub-step must be reviewed by user before merge.

### 3.4 Reject-bar reinforcement

`instructions/software-development.md §워크어라운드 거부 기준` lists telemetry-as-fix as a hard reject. RFC-0044 added the read-side escape valve. This RFC adds the **write-side** escape valve:

> A new persistence write surface that warns on failure and returns a default may emit `metric_*_write_failures` *only if* the PR also (a) uses a typed `Write_failure_reason.t`, and (b) either (b1) propagates `Write_drop` to the caller's caller for a decision, or (b2) labels the PR `WORKAROUND: production-blocking, deprecated path` per the override clause and opens a follow-up to migrate within N PRs.

PRs that add a new write site with `Log.warn ... failed; default_value` without (a) and (b) are declined.

## 4. Stable behavior guarantee

This RFC does **not** change runtime behavior at any of the 20 grandfathered sites until PR-2/3/4/5 migrate them. PR-1 is inert.

Migration PR-2 (`write_meta` cohort) changes the **return contract** of `run_keeper_cycle_with_slot` and related cycle entry points from `keeper_meta` to `(keeper_meta, Write_failure_reason.t) result`. Callers (heartbeat loop, supervisor) are updated to handle `Error` by:

- `Meta_cas_conflict`: retry once with `read_meta` refresh, then escalate.
- `Meta_io_error`: emit existing counter, **propagate up** to the supervisor for fleet-level decision (cohort pause vs single-keeper).
- Other variants: caller-specific (specified per migration PR).

This is *behavior change at migration boundaries only*. PR-1 alone is byte-compatible with `main`.

## 5. Drift guards

- **Lint** (`scripts/lint/write-side-typed-reason.sh`): `rg "Log\.\w+\.\(warn\|error\) .*\(write\|create\|persist\|save\) .* failed" lib/ | wc -l` baseline at RFC merge time. CI fails if the count grows without a matching `Write_failure_reason.t` migration in the same PR.
- **Reject-bar test** (`test/test_write_side_telemetry_as_fix_drift.ml`): structural assertion that the 20 currently-grandfathered sites' line numbers are tracked in `RFC-0077-inventory.csv`. A new site introduced *without* `Write_failure_reason.t` is detected by inventory diff in CI.
- **Counter-example preservation**: `keeper_goal_repair.ml:95` (the existing correct pattern) is referenced as the canonical example in `Write_failure_reason.mli` doc comments.

## 6. Trade-offs

| For | Against |
|-----|---------|
| Closes the symmetric write-side gap RFC-0044 §2 deferred. | 20 sites × per-cohort migration is multi-PR effort; full closure takes weeks. |
| Mirrors RFC-0044's typed pattern — reviewers and AI agents transfer mental model 1:1. | Adds a second module (`Write_failure_reason.t`) parallel to `Read_drop_reason.t`. Could unify later (`Persistence_failure_reason.t`) at the cost of weaker variant naming. |
| Forces explicit caller decision at `Write_drop` — eliminates "stale-meta-return is fine" sleepwalking. | Some sites (alerting JSONL) are genuinely best-effort; the caller decision is `Log + ignore`. RFC accepts this as long as the *type* says so. |
| Prepares the surface for future WAL/journal RFC (still out of scope). | Doesn't *itself* solve recovery — still a visibility improvement. Explicit non-goal §2. |

## 7. Open questions

- **Q1**: Should `Read_drop_reason.t` (RFC-0044) and `Write_failure_reason.t` (this RFC) unify into `Persistence_failure_reason.t` with read/write phantom-type discriminator? **Decision**: defer. Unification is mechanical once both RFCs reach `Active`. Premature unification couples migration cadence.
- **Q2**: `Meta_cas_conflict` retry policy — caller-level retry vs cycle-level retry? RFC-0026 (Work-Conserving Admission) suggests cycle-level. **Decision**: per-migration in PR-2 sub-steps.
- **Q3**: How to handle the cross-module case `keeper_agent_memory_episode.ml` calling into `Workspace` / OAS? Result must propagate through the boundary or be absorbed at the boundary with explicit `Episode_create_error` annotation. **Decision**: PR-3 surfaces this question in the sub-PR.

## 8. Acceptance

- [ ] PR-1 (this PR or follow-up): module `Write_failure_reason.t` + `write_outcome` introduced; inert; lint baseline established.
- [ ] PR-2 (cohort A): `write_meta` migration to typed result at heartbeat / supervisor / keepalive / turn lifecycle.
- [ ] PR-3 (cohort B): external memory + checkpoint + crash persistence migration.
- [ ] PR-4 (cohort C): alerting + approval queue migration.
- [ ] PR-5 (cohort D, optional): migration writes.
- [ ] RFC status promoted to `Active` when PR-2 lands. `Implemented` when cohort A + B + C migrate.
- [ ] Drift guard CI active by PR-2.

## 9. Related RFCs and prior art

- **RFC-0044** (Draft): Read-side counterpart. This RFC's structure mirrors RFC-0044 §3 deliberately.
- **RFC-0042** (Active): Closed sum for keeper turn terminal code — the precedent for "introduce inert typed module first, migrate callers in cohorts" pattern.
- **RFC-0062** (Active): Typed `Tool_result.t` — same pattern at the tool result boundary.
- **RFC-0063** (Draft): Telemetry feedback loop & cooperative scheduling safety — covers retry policy that PR-2 needs.
- **RFC-0071** (Draft): Exhaustive-match sweep codemod — useful tooling for ensuring all `Write_drop` callers handle every variant.
- Counter-example to follow: `lib/keeper/keeper_goal_repair.ml:95` (existing `write_meta failed -> Error _` propagation).
