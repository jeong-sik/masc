# RFC-0109 — CDAL × GOAL Integration Contract

| | |
|---|---|
| **Status** | Draft |
| **Created** | 2026-05-17 |
| **Authors** | claude (Anthropic Opus 4.7) |
| **Reviewers** | (TBD) |
| **Tracks** | `lib/cdal/`, `lib/cdal_runtime/`, `lib/goal/`, `lib/keeper/keeper_cdal_contract.ml` |
| **Related research** | jeong-sik/me PR #1130 (`knowledge/research/2026-05-17-cdal-goal-separation-deep-dive.html`) §3 §5 §6 §7 |
| **Supersedes** | — |
| **Sister RFCs** | RFC-0056 (cdal sublib), RFC-OAS-011 (cdal_runtime sublib), RFC-0067 (Goal-scope observation→claim atomicity) |

## 1. Summary

Numbering note: this RFC was originally drafted as RFC-0107, but RFC-0107
was taken by outbound HTTP stack consolidation on main and RFC-0108 is held
by the atomic JSONL append RFC. This document is therefore renumbered to
RFC-0109.

Bind CDAL verdict to Goal phase transition. Today the two subsystems are
cleanly separated (RFC-0056 + RFC-OAS-011 split them) but **structurally
unconnected**: a CDAL contract `Violated` verdict does not change a
Goal's phase, a Goal in `Awaiting_verification` does not require a CDAL
evaluator pass, and the keeper-level binding is one stringly-typed JSON
field (`Risk_contract.eval_criteria`). The result is two systems
recording the same operational events independently.

This RFC proposes a **three-phase integration**:

- **Phase A** — typed `eval_criteria` (replaces opaque
  `Yojson.Safe.t` with a closed sum type).
- **Phase B** — CDAL verdict → Goal phase auto-transition (verdict
  `Violated` against a goal's verification request triggers
  `Reject_completion`).
- **Phase C** — `verifier_policy` enforcement (a goal carrying a
  verifier policy MUST trigger a CDAL evaluator pass on
  `Request_complete`; quorum counts CDAL verdict as one vote).

Each phase is independently revertible and operator-overridable.

## 2. Motivation

### 2.1 Evidence from the live system (2026-05-17 18:50 KST)

| Symptom | Count | Source |
|---|---|---|
| Total goals in Goal Store | 70 | `masc_goal_list` |
| Active goals | 65 / 70 (93%) | rollup |
| Goals with `(auto)` suffix (Keeper_goal_repair leftovers) | ~33 | title scan |
| Identical-intent `verifier` goals across 10 days | 3 | id collision |
| Goals with `verifier_policy` defined | 6 | record scan |
| Goals with `active_verification_request_id` non-null | **0** | record scan |
| Live keepers | 16 | `masc_keeper_list` |
| Keepers `offline` with `failure:run_error` | 11 / 16 | `last_social_transition_reason` |

Notably: the quorum verification path (`lib/goal/goal_verification.ml`,
700 LoC) is **inert** — zero open requests in live data despite the
infrastructure being present. And 11 keepers report `failure:run_error`
while their `active_goal_ids` remain alive in the Store — the two
subsystems record the same incident separately.

Auto-goal accretion was closed in part by PR #15893 (dedupe + 7d
auto-stagnate). This RFC closes the **integration gap** that PR could
not address.

### 2.2 Current binding (one-way, opaque)

```ocaml
(* lib/keeper/keeper_cdal_contract.ml:38 *)
let of_keeper_meta meta =
  let eval_criteria =
    `Assoc [
      "keeper_name", `String meta.name;
      "agent_name", `String meta.agent_name;
      "active_goal_ids",
        `List (List.map (fun s -> `String s) meta.active_goal_ids);
      ...
    ]
  in
  { runtime_constraints; eval_criteria }
```

`eval_criteria : Yojson.Safe.t` is the typed boundary leak. Every
downstream consumer that wants to filter / route / evaluate by
`active_goal_ids` must JSON-walk this opaque bag. Today **no consumer
does**: CDAL evaluators ignore the embedded goal ids and produce a
verdict purely from agent execution traces.

### 2.3 Workaround Rejection Bar — why the alternatives fail

Per `software-development.md` §Workaround Rejection Bar, the
alternatives we considered each match a forbidden signature:

| Alternative | Signature | Reason rejected |
|---|---|---|
| Dashboard sidebar panel (option A in research HTML §7) | **Telemetry-as-fix** | Makes the gap visible in UI without changing Store behavior |
| Goal Detail with embedded CDAL timeline (option B) | **String classifier** | Requires substring matching `cdal_run_id` ↔ goal until eval_criteria is typed; this RFC's Phase A is the prerequisite |
| Two separate dashboards (option D) | Loss of product unity | Strengthens §2.1's "two systems record the same event" pathology |
| Status quo + counter | **Telemetry-as-fix** | A `cdal_goal_integration_gap_total` counter visualizes the problem without fixing it |

This RFC is the **root fix** path. Each phase is closed-variant typed,
no string classifiers, no N-of-M, no cap/cooldown.

## 3. Non-goals

- Migrating OAS to consume `cdal_runtime` (RFC-OAS-011 ongoing).
- Re-designing `Goal_verification` quorum semantics (separate RFC if
  needed — this RFC only adds CDAL verdict as one vote source).
- Backfilling historical goals with verifier policies — operator
  decides retroactive policy via `masc_goal_upsert`.
- Goal Store schema evolution beyond a single optional field
  (`active_verification_request_id` is already present).
- Dashboard UI redesign — surface the new phase signals via the
  existing SSE event stream (`'cdal_verdict'`, `'verification'`).

## 4. Design — Phase A · Typed `eval_criteria`

### 4.1 New type (in `lib/cdal_runtime/criteria.ml` new module)

```ocaml
(** lib/cdal_runtime/criteria.mli *)
type goal_ref = {
  goal_id : string;
  goal_title : string;  (* witness for log lines, NOT load-bearing *)
}

type t =
  | Active_goals of goal_ref list * { keeper_name : string; agent_name : string }
  | Persona_probe of { persona_id : string; trace_id : string }
  | Verification_request of { goal_id : string; request_id : string }
  | Free of Yojson.Safe.t
    (** Escape hatch for migration. Caller MUST add a TODO comment
        with a target RFC link when constructing [Free]. Lint guard
        in [scripts/pr-rfc-check.sh] §10 (added by this RFC). *)

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
```

### 4.2 Migration of `Risk_contract.eval_criteria`

```ocaml
(* lib/cdal_runtime/risk_contract.mli — BEFORE *)
type t = {
  runtime_constraints : runtime_constraints;
  eval_criteria : Yojson.Safe.t;
}

(* AFTER *)
type t = {
  runtime_constraints : runtime_constraints;
  eval_criteria : Criteria.t;  (* typed *)
}

val to_json : t -> Yojson.Safe.t  (* unchanged wire format *)
val of_json : Yojson.Safe.t -> (t, string) result
```

Wire format stays JSON-compatible. `keeper_cdal_contract.ml` updated to
build `Criteria.Active_goals { ... }` instead of an `Assoc`.

### 4.3 Phase A PR — call sites

| File | Change |
|---|---|
| `lib/cdal_runtime/criteria.{ml,mli}` | New module |
| `lib/cdal_runtime/risk_contract.{ml,mli}` | Switch field type |
| `lib/keeper/keeper_cdal_contract.ml` | Build `Active_goals` instead of JSON `Assoc` |
| `lib/cdal/cdal_eval_v1.ml` | Accept typed criteria (no behavior change in Phase A) |
| `test/test_cdal_eval_v1.ml` | Update fixtures |
| `test/test_keeper_cdal_contract.ml` | New — typed binding round-trip |
| `scripts/pr-rfc-check.sh` | New §10 rule — flag `Criteria.Free` without RFC link |

Estimated change: ~250 LoC.

## 5. Design — Phase B · CDAL verdict → Goal phase auto-transition

### 5.1 New hook in `Cdal_eval_v1.persist`

```ocaml
(* lib/cdal/cdal_eval_v1.ml *)
let persist ~config verdict =
  Goal_phase_bridge.maybe_react ~config verdict;  (* NEW *)
  ... (existing persist logic)
```

### 5.2 New module `Goal_phase_bridge`

```ocaml
(** lib/keeper/goal_phase_bridge.mli *)

val maybe_react :
  config:Coord.config ->
  Cdal_types.contract_verdict ->
  unit
(** [maybe_react] inspects the verdict and, when its [contract_id] is
    bound to an open {!Goal_verification.goal_verification_request} via
    {!Criteria.Verification_request}, calls
    {!Goal_phase.decide_transition} with the matching action.

    Transitions emitted:
    - [verdict.status = Violated] →
      [Goal_phase.decide_transition Awaiting_verification Reject_completion]
    - [verdict.status = Satisfied] when the verifier policy allows CDAL
      auto-approve → [Approve_completion] (gated by
      [Goal_verification.policy_allows_cdal_auto_approve], default
      [false] — operator opt-in).
    - [verdict.status = Inconclusive] → no transition; logged.

    Operator override: any explicit
    [masc_goal_transition ~action:Approve_completion] still wins. The
    bridge writes [last_review_note = "auto-rejected by CDAL verdict
    <run_id>"] so the operator sees the source.

    Best-effort: failures (race, missing goal id) log a warning and do
    not raise. *)
```

### 5.3 Phase B PR — call sites

| File | Change |
|---|---|
| `lib/keeper/goal_phase_bridge.{ml,mli}` | New module |
| `lib/cdal/cdal_eval_v1.ml` | Call `Goal_phase_bridge.maybe_react` after persist |
| `lib/goal/goal_verification.{ml,mli}` | Add `policy_allows_cdal_auto_approve : bool` (default `false`) |
| `test/test_goal_phase_bridge.ml` | New — 3 cases (Violated→Reject, Satisfied+opt-in→Approve, Inconclusive→noop) |
| Prometheus counter | `cdal_goal_phase_transitions_total{outcome=...}` |

Estimated change: ~300 LoC.

### 5.4 Safety properties

- **Idempotent**: re-running the same verdict against an already-
  transitioned goal is a no-op (checked via `phase` before
  transitioning).
- **Operator priority**: any manual `masc_goal_transition` between
  CDAL verdict emission and bridge invocation wins (race window
  ~milliseconds; goal_store version check).
- **Reversible**: `MASC_CDAL_GOAL_BRIDGE_ENABLED=false` disables the
  bridge entirely; pre-Phase-B behavior is restored.

## 6. Design — Phase C · `verifier_policy` enforcement

### 6.1 Behavior change

Today: a goal in `Awaiting_verification` waits passively for `masc_goal_verify`
votes. Operators can `Approve_completion` to bypass.

Phase C: when a goal with `verifier_policy ≠ None` enters
`Awaiting_verification`, `Cdal_eval_v1.evaluate` is **automatically
called** against the keeper's most recent turn for that goal's
`contract_id`. The resulting verdict counts as one vote in the quorum
(toward `required_verdicts`).

### 6.2 Wiring

```ocaml
(* lib/coord_goals.ml — handle_goal_transition *)
let handle_goal_transition ~action goal =
  let next_phase = Goal_phase.decide_transition goal.phase action in
  match next_phase with
  | Awaiting_verification when goal.verifier_policy <> None ->
      (* NEW: trigger CDAL evaluator *)
      Cdal_runtime.Triggers.evaluate_for_goal ~goal_id:goal.id;
      ... (existing logic)
  | _ -> ...
```

### 6.3 Phase C PR — call sites

| File | Change |
|---|---|
| `lib/cdal_runtime/triggers.{ml,mli}` | New module — `evaluate_for_goal` |
| `lib/coord_goals.ml` | Call trigger on transition into Awaiting_verification |
| `lib/goal/goal_verification.ml` | CDAL verdict counted as vote (new vote kind `Cdal_verdict`) |
| `test/test_coord_goals.ml` | Update transition tests |
| `test/test_goal_verification.ml` | New — CDAL vote case |

Estimated change: ~250 LoC.

## 7. Backward compatibility

| Concern | Resolution |
|---|---|
| Existing JSON `eval_criteria` from old keepers | `Criteria.of_json` accepts `Assoc` and wraps as `Free` with deprecation warning. Sunset target: 30 days post-Phase-A merge |
| Existing goals without `verifier_policy` | No behavior change; bridge skips them |
| Existing CDAL runs without bound `goal_id` | No bridge action; logged as `bridge_skip_no_goal_binding` |
| `MASC_CDAL_GOAL_BRIDGE_ENABLED=false` | Reverts to pre-Phase-B behavior |
| Operator manual override (`Approve_completion`) | Always wins over bridge auto-transition |

## 8. Risk

| Risk | Mitigation |
|---|---|
| Bridge cascade — verdict triggers transition triggers verdict | `Goal_phase_bridge` does NOT call back into `Cdal_eval_v1`. Single-direction reaction |
| Stale verdict applied to wrong-version goal | `goal_store.version` checked before transition; mismatch = log warning + skip |
| `Free` escape hatch becomes long-term workaround | `pr-rfc-check.sh` §10 lint guard + 30-day sunset for accepting `Free` from CDAL evaluator (read-side strict after sunset) |
| Phase C breaks existing verification flows | Phase C feature-flagged (`MASC_CDAL_GOAL_VERIFIER_ENFORCE=false` default). Operator opts in per-goal via `policy_allows_cdal_auto_approve` |
| RFC-0067 (goal_store_version observation→claim atomicity) interaction | Phase B reads goal_store version at bridge entry; if version moves between verdict emission and bridge run, skip (operator action wins) |

## 9. Implementation roadmap

| Phase | PR count | Estimated weeks | Dependencies |
|---|---|---|---|
| **A** typed eval_criteria | 1 | 1 | None |
| **B** verdict → phase bridge | 1 | 1.5 | Phase A merged |
| **C** verifier enforcement | 1 | 1.5 | Phase B merged |
| **Cleanup** | 1 | 0.5 | `Free` sunset, lint strict |

Total: **4 PR, ~4 weeks**. Each PR independently revertible.

## 10. Acceptance criteria

- Phase A: `Risk_contract.eval_criteria` is `Criteria.t`; all production
  call sites build `Active_goals` (zero `Free` constructions outside
  tests + explicit RFC-linked sites).
- Phase B: live verdict `Violated` against a bound goal produces a
  `cdal_goal_phase_transitions_total{outcome="reject"}` increment +
  the goal's phase moves to `Executing` (post-reject) within 5s.
- Phase C: goal with verifier policy + `Request_complete` triggers
  exactly one CDAL evaluator run; quorum count includes the verdict
  vote.
- Operator override path tested end-to-end (manual `Approve_completion`
  wins over CDAL bridge auto-reject).

## 11. Test plan

| Layer | Tests |
|---|---|
| Unit | `Criteria.of_json`/`to_json` round-trip; `Goal_phase_bridge.maybe_react` decision matrix |
| Integration | Phase B — temp Goal Store + Cdal_eval_v1 + bridge; verify phase advances |
| Integration | Phase C — `Coord_goals.handle_goal_transition` calls `Cdal_runtime.Triggers.evaluate_for_goal` once |
| Property | Bridge idempotence — re-applying same verdict yields no second transition |
| Live | 1-day live observation post-Phase-B: `cdal_goal_phase_transitions_total{}` counter > 0 if any CDAL evaluator emits Violated |

## 12. Out of scope (future work)

- Cross-keeper CDAL verdict aggregation (one goal, multiple keepers).
- CDAL verdict as input to cascade routing decisions.
- Real-time SSE event for `cdal_goal_phase_transition` (separate from
  existing `'cdal_verdict'` / `'verification'`).
- Frontend UI for displaying verdict ↔ phase lineage (research HTML
  §7 option B partially overlaps; deferred until Phase A merged).

## 13. References

- `knowledge/research/2026-05-17-cdal-goal-separation-deep-dive.html`
  (jeong-sik/me PR #1130) — full code-level analysis, vulnerability
  table V1/V3/V4, improvement table I4/I5/I6.
- RFC-0056 — `lib/cdal/` sublib extraction.
- RFC-OAS-011 — `lib/cdal_runtime/` sublib creation.
- RFC-0067 — Goal-scope observation→claim atomicity (parallel; this
  RFC reads `goal_store.version` at bridge entry).
- PR #15893 — Auto-goal cleanup (closes V2/V5; this RFC closes
  V1/V3/V4).
