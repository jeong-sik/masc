---
title: CDAL × GOAL Integration Contract
rfc: 0109
status: Active
created: 2026-05-17
amended: 2026-05-26
implementation_prs:
  - phase: A
    state: draft
    title: "typed eval_criteria + producer migration + tests"
---

# RFC-0109 — CDAL × GOAL Integration Contract

| | |
|---|---|
| **Status** | Active (frontmatter SSOT) |
| **Created** | 2026-05-17 |
| **Authors** | agent-llm-a (Provider-A Opus 4.7) |
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

> **Amendment 2026-05-26** — original draft proposed an `Active_goals`
> variant based on memory rather than inventory. Live grep over `lib/`
> shows three concrete producer shapes; §4.1 has been rewritten to
> match them. See §4.0 inventory.

### 4.0 Producer inventory (2026-05-26)

| Site | Field shape | Count of caller in main | Maps to variant |
|------|-------------|-------------------------|-----------------|
| `lib/keeper/keeper_cdal_contract.ml:21` | `kind: "keeper_turn_capture_v1"` + 10 fields (keeper_name, agent_name, sandbox_profile, sandbox_image, network_mode, tool_access, tool_denylist, allowed_paths, active_goal_ids, current_task_id_at_start) | 1 (all keeper turn captures) | `Keeper_turn_capture_v1` |
| `lib/masc_contract_catalog.ml:64` | `contract_name`, `description`, `invariants[]` | 3 specs (cascade_critical, keeper_lifecycle, dashboard_telemetry) via `to_risk_contract` | `Contract_catalog_invariants` |
| `lib/jsonl_writer/jsonl_writer_contract_fixture.ml:88` | same as catalog | 0 (orphan — no caller reads it) | typed via `of_yojson` auto-route; emit-side stays raw JSON to preserve `jsonl_writer` leaf-lib boundary |

The original draft's `Active_goals` projection would have lost the
8 sandbox/tool fields that consumers (Dashboard attribution, proof
bundle audit) currently rely on — every keeper site would fall into
`Free`, defeating Phase A.

### 4.1 New type (in `lib/cdal_runtime/criteria.ml` new module)

```ocaml
(** lib/cdal_runtime/criteria.mli *)

(** Tool access JSON projection. Kept as JSON because [cdal_runtime]
    intentionally does not depend on [Keeper_types] (independence
    constraint from RFC-OAS-011). Consumers needing structured tool
    access call [Keeper_types.tool_access_of_meta_json]. *)
type tool_access_json = Yojson.Safe.t

type goal_ref = {
  goal_id : string;
  goal_title : string;  (* witness for log lines, NOT load-bearing *)
}

type t =
  | Keeper_turn_capture_v1 of {
      keeper_name : string;
      agent_name : string;
      sandbox_profile : string;
      sandbox_image : string option;
      network_mode : string;
      tool_access : tool_access_json;
      tool_denylist : string list;
      allowed_paths : string list;
      active_goal_ids : string list;
      current_task_id : string option;
    }
  | Contract_catalog_invariants of {
      contract_name : string;
      description : string;
      invariants : string list;
    }
  | Verification_request of { goal_id : string; request_id : string }
    (** Phase B prereq — no current producer; emitted by
        [Cdal_runtime.Triggers.evaluate_for_goal] in Phase C. *)
  | Persona_probe of { persona_id : string; trace_id : string }
    (** Speculative — deferred. Kept in the typed sum so that future
        producers don't need a follow-up amend. *)
  | Free of Yojson.Safe.t
    (** Migration escape for legacy / unknown shapes (e.g. external
        CDAL fixtures with `success_criteria`/`required_evidence`).
        New construction sites MUST add an inline TODO with a target
        RFC link. Lint guard in [scripts/pr-rfc-check.sh] §10
        (added by this RFC). *)

val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result
val criteria_kind : t -> string
val pp : Format.formatter -> t -> unit
val equal : t -> t -> bool
```

### 4.2 Migration of `Risk_contract.eval_criteria`

```ocaml
(* lib/cdal_runtime/risk_contract.mli — BEFORE *)
type eval_criteria = Yojson.Safe.t [@@deriving yojson, show]

(* AFTER *)
type eval_criteria = Criteria.t
val eval_criteria_to_yojson : eval_criteria -> Yojson.Safe.t
val eval_criteria_of_yojson : Yojson.Safe.t -> (eval_criteria, string) result
val pp_eval_criteria : Format.formatter -> eval_criteria -> unit
```

Wire format stays JSON-compatible. Encoder emits the legacy `kind`
field alongside the new `criteria_kind` discriminator so that existing
log/proof consumers reading `kind` keep working unchanged. Decoder
accepts: (1) new tagged form (`criteria_kind`), (2) legacy `kind`-only
form, (3) untagged catalog shape (recognized by required-field
detection), (4) anything else routes to `Free`.

### 4.3 Phase A PR — call sites

| File | Change |
|------|--------|
| `lib/cdal_runtime/criteria.{ml,mli}` | New module |
| `lib/cdal_runtime/risk_contract.{ml,mli}` | Switch field type to `Criteria.t` |
| `lib/keeper/keeper_cdal_contract.ml` | Build `Keeper_turn_capture_v1 { ... }` |
| `lib/masc_contract_catalog.{ml,mli}` | Build `Contract_catalog_invariants { ... }` |
| `lib/jsonl_writer/jsonl_writer_contract_fixture.ml` | Comment-only update (boundary preservation) |
| `test/test_cdal_criteria.ml` | New — 10 round-trip + legacy-decode + Free tests |
| `test/test_keeper_cdal_contract.ml` | Extend — typed variant assertion + JSON wire compat |
| `test/test_masc_contract_catalog.ml` | Extend — typed variant assertion |
| `test/test_cdal_conformance.ml` | Project criteria to JSON for legacy fixture walk |
| `test/test_cdal_eval_v1.ml` / `test_cdal_judge.ml` / `test_cdal_loader.ml` / `test_cdal_risk_contract.ml` | Wrap raw JSON fixtures in `Criteria.Free` |
| `scripts/pr-rfc-check.sh` | New §10 rule — flag `Criteria.Free` without RFC link (deferred to follow-up PR) |

Actual diff: ~480 LoC (130 production + 350 test). Larger than the
original estimate because §4.0 inventory uncovered 6 test files
threading raw `eval_criteria = \`Assoc [...]` fixtures.

### 4.4 What Phase A does NOT do (deferred to follow-ups)

- `pr-rfc-check.sh` §10 lint guard for `Criteria.Free` — separate PR
  to keep this one focused on the type migration.
- Sunset timer for `Free` arm — deferred until consumer migration in
  Phase B/C/D reduces the open population to a known set.
- Decoder strictness escalation (today: unknown JSON → `Free`; future:
  reject after sunset).

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

## 6.5 Design — Phase D · Task evidence gate ↔ CDAL verdict (new, 2026-05-26)

### 6.5.1 Why Phase D exists

The original RFC scoped integration at the **Goal** boundary
(`Goal.verifier_policy` × `Cdal_verdict_gate`). In live operations
the surface that *actually blocks autonomous keepers* is one layer
below: `lib/tool_task_completion_review.ml:63` — the `submit_for_
verification` evidence gate that rejects `keeper_task_done` calls
lacking a PR URL / artifact ref in notes.

Inventory (`grep -rn workflow_rejection_open_loop_blocked`):

| Site | Mechanism |
|------|-----------|
| `tool_task_completion_review.ml:63` `text_has_verification_artifact_ref` | Substring match over notes for `github.com/.../pull/`, `pr `, `pr:`, `artifact:`, `file:`, `path:`, `commit:`, `branch:` |
| `tool_task.ml:300-314` `done_redirects_to_verification` | Routes `Done_action` to `Submit_for_verification` when `task.contract` is present and `contract_requires_verification` |
| `keeper_tools_oas_handler.ml:120-153` open-loop block | 2-strike scope block on `(task_id, action)`; 2nd workflow_rejection becomes deterministic non-recoverable |

This gate is **typed evidence enforcement via substring classifier** —
it matches the §2.3 workaround signature #2 (string/substring
classifier) that this RFC was supposed to displace. Meanwhile the
typed CDAL verdict layer (`Cdal_types.contract_status` —
`Satisfied`/`Violated`/`Inconclusive` with structured `findings` and
`completeness_gaps`) already exists at `tool_task.ml:528-533` but is
only called *after* Approve/Reject_verification — too late to
inform the gate.

### 6.5.2 Behavior change

When `submit_for_verification` is requested on a task whose
`contract.eval_criteria` carries a CDAL `Verification_request`
(Phase A typed) or the task is bound to a goal whose verdict is
queryable via `Cdal_verdict_gate.lookup_latest_verdict ~task_id`:

| CDAL verdict | Gate decision | Substring shim |
|--------------|---------------|----------------|
| `Some Satisfied` | **Pass** (typed evidence overrides string match) | Skipped |
| `Some Violated` | **Reject** with typed `findings[]` in error payload | Skipped |
| `Some Inconclusive` | **Pass** only if `contract.required_evidence` satisfied; else `Reject` with completeness_gaps | Skipped |
| `None` AND `task.contract = None` | **Pass** (analysis-only task; current gate bypass behavior preserved) | Skipped |
| `None` AND `task.contract = Some _` | **Fall through** to current substring shim (legacy behavior) | Active |

### 6.5.3 Wiring sketch

```ocaml
(* lib/tool_task.ml — replace the inline call site *)
let submit_evidence_error =
  match requested_action with
  | Submit_for_verification | Submit_pr_evidence
  | Done_action when done_redirects_to_verification ->
    (match Cdal_verdict_gate.lookup_latest_verdict ~task_id with
     | Some { status = Satisfied; _ } -> None
     | Some ({ status = Violated; _ } as v) ->
       Some (Cdal_evidence_error.of_verdict v)
     | Some ({ status = Inconclusive; _ } as v) ->
       Cdal_evidence_error.inconclusive_with_required_evidence v task
     | None when task_opt |> Option.bind (fun t -> t.contract) |> Option.is_none ->
       None  (* analysis-only task: gate bypass *)
     | None ->
       (* legacy substring shim, preserved *)
       Tool_task_completion_review.verification_submission_evidence_error
         ~notes ~handoff_context)
  | _ -> None
```

`Cdal_evidence_error` is a new helper that projects typed findings
to the operator-readable error payload, replacing the current
hint-string-only feedback.

### 6.5.4 Phase D PR — call sites

| File | Change |
|------|--------|
| `lib/cdal_runtime/cdal_evidence_error.{ml,mli}` | New — verdict → workflow_rejection payload projection with findings |
| `lib/tool_task.ml` | Replace inline substring-only call with the layered Cdal-first decision |
| `lib/tool_task_completion_review.ml` | Demote `verification_submission_evidence_error` to fallback; keep public surface for `task.contract = Some _` legacy path |
| `lib/keeper/keeper_tools_oas_handler.ml` | Carry typed findings through `workflow_rejection_payload_json` so the operator sees verdict.findings, not just a hint string |
| `test/test_tool_task_evidence_gate.ml` | New — 5-case decision matrix (table above) |
| `test/test_tool_task_completion_review.ml` | Update — gate bypass for task.contract = None |

Estimated change: ~350 LoC.

### 6.5.5 Operator-visible improvement

Today's reject message (from `text_has_verification_artifact_ref` hint):
> "submit_for_verification requires verification evidence: include pr_url for the draft PR, a PR # reference, or an explicit artifact/file/path/commit/branch reference in notes."

Phase D reject message (from typed CDAL verdict):
> "CDAL verdict for task `task-cdal-001` is Violated. Findings:
> - `check_id=invariant_keeper_lifecycle.zombie_phase_reports_to_supervisor`: observed `fiber_zombie`, expected `KH_zombie reported within 30s`. trace_ref=proof-store://run-789/tool_traces/trace-004
> - `check_id=invariant_dashboard_telemetry.cascade_hits_visible_realtime`: completeness gap — `dashboard_attribution` events not emitted in the run."

This is the user-visible payoff of typed integration: the operator
sees *which contract clause failed* instead of "add a PR URL".

### 6.5.6 Dependency chain

Phase D depends on Phase A (typed criteria) AND Phase B (verdict
binding mechanism). Phase D does **not** depend on Phase C
(verifier policy enforcement); it works against any task with a
CDAL verdict regardless of goal-level verifier policy.

Recommended sequencing: A → B → D → C. Phase D before C means the
operator pain point (autonomous keeper task-done loop) is fixed
earlier; Phase C is the long-tail completeness work.

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
| **A** typed eval_criteria | 1 | 1 (in progress, 2026-05-26) | None |
| **B** verdict → phase bridge | 1 | 1.5 | Phase A merged |
| **D** task evidence gate ↔ CDAL (added 2026-05-26) | 1 | 1.5 | Phase A + B merged |
| **C** verifier enforcement | 1 | 1.5 | Phase B merged (independent of D) |
| **Cleanup** | 1 | 0.5 | `Free` sunset, lint strict |

Total: **5 PR, ~5.5 weeks**. Each PR independently revertible.
Phases B/C/D can run in parallel once A is merged. Phase D is the
direct fix for the operator-visible "keeper_task_done open-loop
block" pain that triggered this amendment.

## 10. Acceptance criteria

- Phase A: `Risk_contract.eval_criteria` is `Criteria.t`; the two
  production call sites build `Keeper_turn_capture_v1` /
  `Contract_catalog_invariants` (zero `Free` constructions outside
  tests + the documented orphan in `jsonl_writer_contract_fixture`).
- Phase B: live verdict `Violated` against a bound goal produces a
  `cdal_goal_phase_transitions_total{outcome="reject"}` increment +
  the goal's phase moves to `Executing` (post-reject) within 5s.
- Phase C: goal with verifier policy + `Request_complete` triggers
  exactly one CDAL evaluator run; quorum count includes the verdict
  vote.
- Phase D: a task with `Cdal_verdict.Satisfied` passes
  `keeper_task_done` without any notes-string artifact ref; a task
  with `Cdal_verdict.Violated` rejects with typed findings in the
  error payload, NOT the legacy "include pr_url..." hint string.
- Operator override path tested end-to-end (manual
  `Approve_completion` wins over CDAL bridge auto-reject).

## 11. Test plan

| Layer | Tests |
|---|---|
| Unit (Phase A) | `Criteria.of_yojson`/`to_yojson` round-trip for all 5 variants; legacy `kind`-only decoder; untagged catalog-shape decoder; unknown-shape fallback to `Free`; non-object fallback to `Free`; `criteria_kind` precedence over legacy `kind` (see `test/test_cdal_criteria.ml`) |
| Unit (Phase A) | Keeper meta → `Keeper_turn_capture_v1` typed projection + JSON wire compat (see `test/test_keeper_cdal_contract.ml`) |
| Unit (Phase A) | Catalog spec → `Contract_catalog_invariants` typed projection (see `test/test_masc_contract_catalog.ml`) |
| Unit (Phase B) | `Goal_phase_bridge.maybe_react` decision matrix |
| Integration (Phase B) | Temp Goal Store + Cdal_eval_v1 + bridge; verify phase advances |
| Integration (Phase C) | `Coord_goals.handle_goal_transition` calls `Cdal_runtime.Triggers.evaluate_for_goal` once |
| Unit (Phase D) | 5-case decision matrix from §6.5.2: Satisfied → pass; Violated → reject with findings; Inconclusive → required_evidence check; None + contract=None → bypass; None + contract=Some → substring fallback |
| Integration (Phase D) | End-to-end keeper_task_done with a bound Cdal verdict; assert workflow_rejection payload carries typed `findings[]` not just hint string |
| Property | Bridge idempotence — re-applying same verdict yields no second transition |
| Live | 1-day live observation post-Phase-B: `cdal_goal_phase_transitions_total{}` counter > 0 if any CDAL evaluator emits Violated |
| Live | 1-day live observation post-Phase-D: `workflow_rejection_open_loop_blocked` rate drops on analysis-only tasks (contract=None bypass) |

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
