# RFC: Keeper Liveness SSOT — closed-sum FSM for no-progress / paused / resume

- Status: Draft
- Audit finding: KLV-1 (P1) — structural root of "keepers keep stalling and never resume"
- Source: keeper-runtime deep audit (2026-06-29), §1a/§3/§6/§7
- Target repo: `~/me/workspace/yousleepwhen/masc` (OCaml 5.x + Eio)
- Related RFC/issues: RFC-0239 (no-progress predicate), RFC-0246 (wake tombstone), RFC-0042 (closed-sum over string classifiers), #9926, #10765
- Author: keeper-runtime audit (draft for review)

---

## 1. Summary

The "is this keeper looping / paused / resumable" fact is currently recorded in **8 independent stores** (one volatile `Hashtbl`, three `keeper_meta` fields, one registry string-coded field, one phase-FSM condition, one event-queue stimulus, one `Atomic.t`), plus one derived reader (`Keeper_wake_tombstone`). No single type owns it. Readers reconstruct "is looping" by OR-ing three of these stores (`keeper_turn.ml:144-149`), which directly contradicts the detector module's own docstring claim that "exactly one place decides 'this keeper is looping'" (`keeper_no_progress_loop_detector.ml:100-104`).

This RFC proposes a single closed-sum FSM — `Keeper_liveness.t` — hosted as one new field on the persisted `agent_runtime_state` record. `meta.paused`, `meta.auto_resume_after_sec`, the detector's `streak`/`detected_latched`, and the `"no_progress_loop"` string failure code all become **derived projections** of this type. Migration is staged in 4 independently-shippable steps so the narrowing of `meta.paused` from a writable `bool` to a read-only projection does not block legitimate writers (the "constraint hell" risk the user flagged).

Design principles (CLAUDE.md): parse-don't-validate (legal states only), SSOT, no string classifiers, no silent failure, no catch-all `_ ->`, immutable-first.

---

## 2. Motivation

masc-improver evidence (recorded in the detector docstring, `keeper_no_progress_loop_detector.ml:1-12`): a single keeper spent **13.3 hours of LLM time and 4.19M tokens across 40+ consecutive no-progress turns**. The detector closes the *observability* half but explicitly defers the *prevention/recovery* half to a follow-up — and that follow-up state is exactly what fragmented across 8 stores.

Two concrete failure modes follow from the fragmentation:

1. **Desync → unresumable limbo.** `clear_for_operator_resume` (`keeper_unified_turn_no_progress.ml:98-165`) must clear four stores in sequence — drop the event-queue stimulus, reset the detector latch, clear the registry failure reason, clear `meta.last_blocker`. If the *first cosmetic* step (`drop_by_post_id`, a disk op) fails, it returns `Error` (line 106-111) **before** clearing the authoritative `meta.paused`/blocker — so a transient disk error on a low-value cleanup permanently blocks the high-value resume write. The no-progress pause uses `Manual_resume_required` (`keeper_unified_turn_no_progress.ml:44`), so no other recovery path exists. This is audit finding KLV-2; it is a direct consequence of resume requiring N writes across N stores instead of one transition over one type.

2. **N-of-M drift patches.** The report cites 7 recent PRs (#22594/#22590/#22539/#22537/#22497/#22500/#22518) each patching one store's drift — the classic "abstraction failure admits N-of-M patches" signature from CLAUDE.md §워크어라운드. A single owning type makes the compiler enforce all sites at once.

The detector's own contract is internally inconsistent: it documents "exactly one place decides this keeper is looping" (`keeper_no_progress_loop_detector.ml:101-104`), but the actual decision is computed by `keeper_turn.ml:144-149`:

```ocaml
let has_direct_success_no_progress_pause ~(config : Workspace.config) (meta : keeper_meta) =
  meta.paused                                                        (* store #2 *)
  && (has_no_progress_loop_blocker meta                              (* store #4 *)
      || Keeper_no_progress_loop_detector.is_latched ~keeper_name:meta.name   (* store #1 *)
      || has_no_progress_failure_reason ~base_path:config.base_path meta.name) (* store #5 *)
```

Four stores, OR-combined. The contradiction is structural, not a comment bug.

---

## 3. Current State — store map

Every place that records "looping / paused / resumable", with exact `file:line`, type, and writers. Verified read-only against the tree at audit time.

| # | Store | Location (file:line) | Type | Written by |
|---|-------|----------------------|------|------------|
| 1 | detector volatile state | `keeper_no_progress_loop_detector.ml:15-20` | `(string, {mutable streak:int; mutable detected_latched:bool}) Hashtbl.t` | `record_turn` (`.ml:59-92`), `reset` (`.ml:111-114`), `reset_all_for_test` (`.ml:116-117`) |
| 2 | `meta.paused` | `keeper_meta_contract.ml:509` | `bool` | `handle_crash_auto_pause` (`keeper_supervisor_pause_policy.ml:195`), `handle_auto_pause_from_meta` (`...:416`), `clear_direct_success_no_progress_pause` (`keeper_turn.ml:194`), `sync_keeper_paused_state_with_resume_policy` (`keeper_turn_runtime_budget.ml:735`) via `mark_loop_detected` (`keeper_unified_turn_no_progress.ml:41-45`) |
| 3 | `meta.auto_resume_after_sec` | `keeper_meta_contract.ml:510` | `float option` | same pause paths as #2; cleared at `keeper_turn.ml:195` |
| 4 | `runtime.last_blocker` (`klass = No_progress_loop`) | `keeper_meta_contract.ml:471`; class at `:157` | `blocker_info option` | `mark_loop_detected` (`keeper_unified_turn_no_progress.ml:28-39`); cleared in `clear_if_recovered` (`...:92-95`), `clear_no_progress_meta_blocker` (`keeper_turn.ml:151-155`) |
| 5 | `entry.last_failure_reason` (`Provider_runtime_error { code = "no_progress_loop" }`) | `keeper_registry_types.ml:100`; variant `keeper_registry_types_failure.ml:79`; **string code** `keeper_unified_turn_no_progress.ml:3` | `failure_reason option` with **string-matched code** | `set_failure_reason` (`keeper_unified_turn_no_progress.ml:24`); cleared in `clear_if_recovered` (`...:81-84`), `clear_for_operator_resume` (`...:138`), `persist_direct_success_no_progress_resume` (`keeper_turn.ml:157-180`) |
| 6 | phase FSM `Paused` (via `conditions.operator_paused`) | `keeper_state_machine_types.mli:10,29`; derived `keeper_state_machine.ml:146`; set `:233-234` | `phase` / `conditions.operator_paused : bool` | `Operator_pause` / `Operator_resume` events (`keeper_state_machine.ml:233-234`) |
| 7 | event-queue recovery stimulus | post_id `"no-progress-loop:" ^ name` `keeper_unified_turn_no_progress.ml:5`; payload `No_progress_recovery` `keeper_runtime/keeper_event_queue.ml` | `Keeper_event_queue.stimulus` | enqueued via generic event-queue path; **dropped** in `clear_for_operator_resume` (`...:101-105`) |
| 8 | `entry.fiber_wakeup` | `keeper_registry_types.ml:89` | `bool Atomic.t` | `keeper_registry.ml:404,412,432` (`wakeup`), cleared `:188,1062` |
| (d) | `Keeper_wake_tombstone` | `keeper_wake_tombstone.mli`; reads store #1 at `keeper_wake_tombstone.ml:52` | derived `wake_decision` (closed sum, no own store) | — reader only (`is_latched`) |

**Count: 8 authoritative stores + 1 derived reader.** Stores #1, #2, #4, #5 redundantly answer the same question ("is this keeper in a no-progress pause"); #3 and #6 answer "is it paused and how does it resume"; #7 is the recovery side-channel; #8 is the wake latch. There is no type that makes "paused" imply "has a reason and a resume policy" — the limbo state in §2.1 is *representable*.

**Detector docstring contradiction — confirmed.** `keeper_no_progress_loop_detector.ml:100-104`:

> "The detector owns the single source of truth (streak + detected_latched); the tombstone gate reads it rather than duplicating state, so exactly one place decides 'this keeper is looping'."

This is true only for the *wake-tombstone* reader (store #1 → derived (d)). It is false for the *pause/resume* decision, which OR-s stores #1/#2/#4/#5 in `keeper_turn.ml:144-149`. The detector knows the streak; it does not own the pause/resume truth.

Secondary redundancy inside store #1 itself: `detected_latched` (`.ml:17`) is fully derivable from `streak >= threshold` but kept as a separate `mutable` bool, so the two can desync (e.g. a manual `reset` of one without the other). The SSOT removes `detected_latched` by deriving it.

---

## 4. Design — the SSOT type

### 4.1 Core closed sum

New leaf module `Keeper_liveness` (file `lib/keeper/keeper_liveness.ml` / `.mli`), dependency on stdlib only — no keeper module imports, so no boundary violation (it is depended *on*, never depends back).

```ocaml
(* lib/keeper/keeper_liveness.mli *)

(** Why a keeper is paused. Closed sum: adding a constructor breaks every
    match at compile time (RFC-0042). No "_ ->" catch-all anywhere. *)
type pause_reason =
  | Operator              (** masc_keeper pause / API; investigation tool *)
  | No_progress_loop      (** detector latch crossed threshold (RFC-0239/0246) *)
  | Completion_contract   (** completion-contract violation pause *)
  | Crash_backoff of { strikes : int }
      (** stale-termination-storm / provider-timeout-loop / fiber crash cohort
          (Keeper_supervisor_pause_policy); [strikes] carries the loop count. *)

(** How a paused keeper returns to Active. Subsumes the two currently-separate
    fields [meta.paused] (bool) + [meta.auto_resume_after_sec] (float option)
    and the supervisor's [crash_pause_resume_policy]. *)
type resume_policy =
  | Manual_resume_required
  | Auto_resume_with_backoff of { after_sec : float }

type state =
  | Active
  | Paused of { reason : pause_reason; since : float; resume : resume_policy }

(** [no_progress_streak] is orthogonal to paused/active: it accrues while
    [Active] and, at threshold, drives the [Active -> Paused No_progress_loop]
    transition. Kept as a top-level field, not inside a constructor, because a
    keeper can carry a streak while still Active (pre-threshold). *)
type t = { state : state; no_progress_streak : int }

val active : t                                   (** {state=Active; streak=0} *)
```

`no_progress_streak` as a top-level field (per the brief) keeps the type total: every `t` has a well-defined streak whether Active or Paused, and `detected_latched` disappears — "latched" becomes a projection (§4.2).

### 4.2 Projections (read-only functions of the FSM)

`meta.paused` MUST become a derived projection, never an independently-writable bool. The projection signatures:

```ocaml
val is_paused : t -> bool
(** [is_paused {state=Paused _; _} = true]. Replaces the [meta.paused] field
    read everywhere (dashboard, status bridge, phase derivation). *)

val pause_reason : t -> pause_reason option
(** [Some r] iff Paused. Replaces the OR over last_blocker/failure_reason. *)

val auto_resume_after_sec : t -> float option
(** [Some sec] iff [Paused { resume = Auto_resume_with_backoff { after_sec }; _ }].
    Replaces the independent [meta.auto_resume_after_sec] field. *)

val no_progress_streak : t -> int                (** replaces detector current_streak *)

val is_no_progress_latched : threshold:int -> t -> bool
(** SSOT replacement for keeper_turn.ml:144-149's 3-store OR and the detector's
    [detected_latched]. Definition:
      [is_no_progress_latched ~threshold t =
         (match t.state with Paused { reason = No_progress_loop; _ } -> true | _ -> false)
         || t.no_progress_streak >= threshold]
    One expression; no store can drift from another because there is only one store. *)
```

The phase FSM's `conditions.operator_paused` (`keeper_state_machine_types.mli:29`) is set from `is_paused` instead of a free-standing `Operator_pause`/`Operator_resume` bool flip — making store #6 a projection too (Stage 2).

### 4.3 Host module — extend, do not parallel

Host the field on the existing persisted record `agent_runtime_state` in `keeper_meta_contract.ml` (the type begins at `keeper_meta_contract.ml:454`), adding exactly one field:

```ocaml
type agent_runtime_state =
  { usage : usage_metrics
  ; (* ... existing fields ... *)
  ; last_blocker : blocker_info option        (* existing, keeper_meta_contract.ml:471 *)
  ; liveness : Keeper_liveness.t              (* NEW — SSOT *)
  ; (* ... *)
  }
```

Rationale for the host choice (alternatives considered in §7):
- The phase FSM (`Keeper_state_machine`, `lib/keeper_registry/`) is **in-memory, derived** state recomputed from `conditions` each tick (`keeper_state_machine.ml:146`). It is not the persistence boundary; pause *reason* and *streak* must survive a server restart, so the SSOT cannot live only in the FSM. We extend the FSM to *project from* liveness (Stage 2), not host it.
- `agent_runtime_state` already persists `last_blocker` and is the natural home for runtime liveness. Extending it (one field) keeps a single persisted record rather than introducing a parallel store — the explicit anti-goal.
- `Keeper_liveness` is a separate leaf module (not inlined) because `keeper_meta_contract.ml` is already 797 lines and the closed-sum + projections need isolated unit tests.

Note on naming: `Keeper_failure_policy` (`lib/keeper_failure_policy/`) already exports a `liveness` type (`Watchdog_stale | Unknown_liveness`). The new type is `Keeper_liveness.t`, module-qualified, so there is no collision; do not name a bare `liveness` in `keeper_meta_contract`.

### 4.4 Serialization & migration of on-disk meta

Serialize a `"liveness"` object alongside (during migration) the legacy fields in `keeper_meta_json.ml` (current `paused`/`auto_resume_after_sec` at `:86-87`, `last_blocker` at `:72-73`):

```json
"liveness": {
  "state": "paused",
  "reason": { "kind": "no_progress_loop" },
  "since": 1751200000.0,
  "resume": { "kind": "manual_required" },
  "no_progress_streak": 12
}
```

Parse boundary (parse-don't-validate) in `keeper_meta_json_parse.ml` (legacy fields parsed at `:379-380`, `:348-418`):

```
parse_liveness json =
  match assoc "liveness" json with
  | Some obj -> decode_liveness obj          (* authoritative once present *)
  | None ->
      (* Migration default for pre-RFC on-disk meta: reconstruct from the
         legacy triple. Total mapping, no silent fallthrough. *)
      match (legacy_paused, legacy_blocker_klass, legacy_auto_resume) with
      | false, _, _                       -> Keeper_liveness.active_with_streak 0
      | true,  Some No_progress_loop, _   -> Paused { No_progress_loop; Manual_resume_required }
      | true,  Some Completion_contract_violation, _ -> Paused { Completion_contract; Manual_resume_required }
      | true,  _, Some sec                -> Paused { Crash_backoff {strikes=0}; Auto_resume_with_backoff sec }
      | true,  _, None                    -> Paused { Operator; Manual_resume_required }
```

`since` defaults to `meta.updated_at` epoch when reconstructing (the field the supervisor already keys auto-resume off, `keeper_meta_contract.ml:511-517`). Every legacy combination maps to exactly one `Keeper_liveness.t`; there is no `_ -> assert false` and no permissive default (CLAUDE.md anti-pattern #2). Round-trip identity is a test gate (§6).

---

## 5. Migration plan (staged, no big-bang)

Each stage is independently shippable and testable. The narrowing of `meta.paused` happens only at Stage 3, after every reader has moved.

### Stage 1 — additive: type + field + dual-write
- Add `Keeper_liveness` module + projections + unit tests.
- Add `liveness` field to `agent_runtime_state`; default `Keeper_liveness.active` for new keepers.
- Every existing pause/resume writer **also** sets `liveness` (dual-write): `mark_loop_detected`, `handle_crash_auto_pause`, `handle_auto_pause_from_meta`, `clear_*`. The legacy stores remain the read source.
- Serialize `liveness` (write) and parse it (read, with the §4.4 legacy reconstruction).
- Ship gate: build green, `liveness` round-trips, no reader changed. Risk ≈ 0 (purely additive).

### Stage 2 — migrate readers to projections, one per PR
- `keeper_turn.ml:144-149` OR-of-3 → `Keeper_liveness.is_no_progress_latched ~threshold meta.runtime.liveness`. (one PR + regression test)
- `Keeper_wake_tombstone.decide` (`keeper_wake_tombstone.ml:52`) → projection. (one PR)
- detector `is_latched` / `current_streak` callers → projection. (one PR)
- phase FSM `conditions.operator_paused` set from `is_paused`. (one PR)
- Each PR: swap one reader, keep dual-write, add a test asserting old-store value == projection value for the migrated reader. No two readers in one PR (so a regression bisects to one site).

### Stage 3 — make legacy stores derived
- `meta.paused` and `meta.auto_resume_after_sec`: remove all independent writers; the only setter becomes a `Keeper_liveness` transition. For wire/back-compat (dashboard consumes `"paused"` — `keeper_status_bridge.ml`, `keeper_status_detail.ml`, `keeper_status_runtime.ml`, `keeper_activation_readiness.ml`), `keeper_meta_json.ml` *projects* `"paused": is_paused liveness` at serialization. Internal code stops reading the field.
- Registry store #5: drop the `"no_progress_loop"` **string code** path; failure-reason no-progress is read from `liveness.pause_reason`. (closes the string-classifier signature, RFC-0042 aligned)
- detector becomes a pure transition: `record_turn` returns the next `Keeper_liveness.t` from the previous one; the streak source becomes `meta.runtime.liveness.no_progress_streak`, not the Hashtbl.

### Stage 4 — delete the volatile state
- Delete the `Hashtbl` and `detected_latched` in `keeper_no_progress_loop_detector.ml:15-20` (now redundant with the persisted field; survives restart for free).
- Remove the OR predicate and the dual-write scaffolding from Stage 1.
- Optionally drop the in-record `paused`/`auto_resume_after_sec` fields, keeping only a `[@@deriving]`/projection for JSON wire compat.
- Ship gate: `rg` shows zero independent writers of `paused`/`detected_latched`/`"no_progress_loop"` string; TLA+ + exhaustiveness tests green.

---

## 6. Testing strategy

1. **Closed-sum exhaustiveness (compile-time).** `pause_reason`, `resume_policy`, `state` matched without `_ ->`. Adding a constructor fails the build at every projection — the structural guarantee. A drift-guard test is unnecessary because the compiler is the guard (unlike the string code it replaces).
2. **Per-variant projection unit tests.** For each constructor of `state`/`pause_reason`/`resume_policy`: assert `is_paused`, `pause_reason`, `auto_resume_after_sec`, `is_no_progress_latched` return the intended value. Table-driven over all variants.
3. **Serialization round-trip (property).** `decode (encode t) = t` for every variant, including `Crash_backoff { strikes }` and `Auto_resume_with_backoff { after_sec }`. Plus a fixed-vector test for the on-disk JSON shape.
4. **Legacy migration table.** Each `(paused, blocker_klass, auto_resume)` legacy tuple → expected `Keeper_liveness.t` (the §4.4 mapping), asserted exhaustively.
5. **Illegal-state-unrepresentable regression.** Property: `∀ t. is_paused t ⇒ pause_reason t ≠ None ∧ (resume policy is decidable)`. By construction `Paused` carries both `reason` and `resume`, so "paused with no reason / no resume path" is unrepresentable — the §2.1 limbo cannot be constructed. The test exists to lock the invariant against future field additions.
6. **TLA+ transition-matrix model (fits the CLAUDE.md TLA+ Bug Model pattern).** Model `Active ↔ Paused` with `since`/`resume`. `SafetyInvariant`: every reachable `Paused` has a reachable `Active` (a resume edge). `BugAction`: `ResumeEdgeDropped` (mirrors KLV-2: resume blocked on a failed cosmetic step). Clean spec: no error. `-buggy.cfg` (`Next \/ ResumeEdgeDropped`): invariant violated → proves the invariant actually catches the unresumable-limbo bug. Place under `specs/keeper-liveness/`.

---

## 7. Risks (mandatory)

### 7.1 "Constraint hell" — narrowing `meta.paused` (bool → read-only projection)
`meta.paused` is a persisted, widely-consumed bool (dashboard, status bridge, activation readiness, phase derivation). Flipping it to read-only in one patch would block every legitimate writer (supervisor pause, operator pause, turn-success resume). Mitigation is the staged path itself:
- Stages 1-2 keep the legacy bool writable; writers dual-write liveness; readers move incrementally.
- Only at Stage 3, after all readers consume the projection, does `paused` lose its independent writers — and even then it is *projected* at the JSON boundary (`is_paused liveness`) so external consumers (dashboard) are untouched.
- The legitimate writers are not blocked: they move from `{ meta with paused = true; auto_resume_after_sec = ... }` to a single `Keeper_liveness` transition setter. One funnel, not zero writers.
This is RFC-scale precisely because of the consumer breadth; the 4 stages bound the blast radius per PR.

### 7.2 "One keeper stop → all stop" — Eio fail-fast isolation
`Eio.Fiber.fork` is fail-fast: an uncaught exception in a forked fiber calls `Switch.fail`, which cancels **all siblings on the same switch** (Eio docs §Fiber/§Switch). A naive consolidation that handled pause inside a shared fleet switch would turn one keeper's pause-write exception into a fleet-wide cancel.
- This RFC's change is **in-memory + JSON state**, not fiber topology, so it does not itself fork on a shared switch. But the constraint is binding on *how* the liveness setter is invoked from sweeps/turns.
- **Isolation requirement (normative):** any sweep or turn that mutates liveness for a keeper runs under that keeper's own `Switch.run` with a boundary `try/with` that (a) **re-raises `Eio.Cancel.Cancelled`** (never swallow it — swallowing breaks structured cancellation) and (b) converts other exceptions to a `Result` for the caller. The existing code already does this correctly in `clear_for_operator_resume` (`keeper_unified_turn_no_progress.ml:124`: `| Eio.Cancel.Cancelled _ as exn -> raise exn`); the migration must preserve, not regress, this pattern.
- A reaper / supervisor sweep fiber must use `Fiber.fork_daemon` (or per-worker `Switch.run`), not a bare `Fiber.fork` on the fleet switch, so a single keeper's failure does not cancel the fleet (report §7, item #6).

### 7.3 Migration window desync (Stage 1-2 dual-write)
During dual-write, the legacy store and `liveness` could diverge if a writer updates one but not the other. Mitigation: Stage 1 routes **all** pause/resume mutations through a single helper that updates both atomically within the same `map_runtime`/meta write; a Stage-1 test asserts post-write `is_paused liveness == meta.paused` for every pause path. Drift is detectable and short-lived (closed at Stage 3).

---

## 8. Alternatives

| Alt | Description | Verdict |
|-----|-------------|---------|
| A | Keep all 8 stores; add a per-tick reconciler that resyncs them | **Reject.** Telemetry/repair-as-fix (CLAUDE.md workaround signature). The desync window remains; reconciler is new surface to drift. |
| B | Collapse to a single `paused : bool`, drop streak/reason/policy | **Reject.** Loses resume policy + reason; cannot distinguish operator vs no-progress vs crash-backoff; reintroduces the unresumable-limbo (§2.1) because "paused" no longer implies "has a resume path". |
| C | Host SSOT only in the phase FSM `conditions` | **Reject.** `conditions` is in-memory, recomputed each tick (`keeper_state_machine.ml:146`); pause reason + streak must survive restart. The persistence boundary is `agent_runtime_state`. |
| D (chosen) | One closed-sum `Keeper_liveness.t` on `agent_runtime_state`; legacy stores → projections; staged migration | Accept. |

---

## 9. References

- Parse, don't validate — Alexis King: https://lexi-lambda.github.io/blog/2019/11/05/parse-don-t-validate/
- Closed-sum exhaustiveness (Real World OCaml, Variants): https://dev.realworldocaml.org/variants.html
- Eio.Switch (structured cancellation / `Switch.fail` cascade): https://ocaml-multicore.github.io/eio/eio/Eio/Switch/index.html
- Eio.Fiber (`fork` fail-fast, `fork_daemon`): https://ocaml-multicore.github.io/eio/eio/Eio/Fiber/index.html
- Source: keeper-runtime deep audit (2026-06-29) — §1a (8-store map), §3 (KLV-2 fail-closed resume), §6 (migration), §7 (constraint-hell / one-stop-all-stop risk)
- Internal: RFC-0239 (no-progress predicate), RFC-0246 (wake tombstone), RFC-0042 (closed-sum over string classifiers)
