---
rfc: "0072"
title: "Type-encoded keeper sub-FSM transitions (cascade + turn_phase)"
status: Draft
created: 2026-05-12
updated: 2026-05-12
author: vincent
supersedes: []
superseded_by: null
related: ["0002", "0039", "0042", "0046"]
implementation_prs: []
---

# RFC-0072 — Type-encoded keeper sub-FSM transitions (cascade + turn_phase)

## 1. Background

Keeper composite lifecycle (`RFC-0003`) is partitioned into 4 sub-FSM axes that the keeper registry maintains as one `current_turn_observation` record:

| Axis | Type | Variants | Validator | Status |
|---|---|---|---|---|
| Decision stage | `decision_stage` | 4 | `validate_decision_transition` | **Compile-time enforced** (PR #14887 + #14893) |
| Cascade state | `cascade_state` | 5 | `validate_cascade_transition` | Runtime `invalid_arg` |
| Turn phase | `turn_phase` | 8+ | `validate_turn_phase_transition` | Runtime `invalid_arg` |
| Compaction stage | `compaction_stage` | (TBD) | `validate_compaction_transition` | Runtime (separate audit) |

PR #14887 (`set_turn_decision_stage`) + PR #14893 (`validate_decision_transition`) closed the decision axis by **input type refinement**: a `decision_stage_active` type that excludes `Decision_undecided` makes the 3 forbidden `<active>_to_undecided` transitions unrepresentable.

This RFC proposes extending the type-encoded enforcement to the **cascade** and **turn_phase** axes.

## 2. Problem

The decision axis was uniquely closable by single-target refinement because its 3 forbidden pairs all target the same state (`Decision_undecided`). The cascade and turn_phase axes do not have this property.

### 2.1 Cascade — 7 forbidden pairs scattered by source

`cascade_state` = { Idle, Selecting, Trying, Done, Exhausted } (5 variants). The 25-pair matrix admits 18 transitions and forbids 7:

| Source | Forbidden targets |
|---|---|
| Idle | Trying, Done, Exhausted |
| Selecting | Done, Exhausted |
| Done | Exhausted |
| Exhausted | Done |

Per-target valid sources:

| Target | Valid sources | Forbidden sources |
|---|---|---|
| Idle | any | (none) |
| Selecting | any | (none) |
| Trying | Selecting, Trying, Done, Exhausted | **Idle** |
| Done | Trying, Done | **Idle, Selecting, Exhausted** |
| Exhausted | Trying, Exhausted | **Idle, Selecting, Done** |

A single-axis type exclusion (decision pattern) cannot encode this — `Trying`, `Done`, `Exhausted` each have different source restrictions.

### 2.2 Turn phase — even more scattered

`turn_phase` = { Idle, Prompting, Routing, Executing, Compacting, Finalizing, Exhausted, ... } (8+ variants). The matrix has 60+ pairs with forbidden cycles like `Idle -> Compacting` (Idle has no measurement to compact). The forbidden set is larger and the topology is acyclic-with-retries, not a simple sub-sum.

### 2.3 Current enforcement is runtime-only

Both validators raise `Invalid_argument` at the moment a forbidden pair is dispatched through `set_turn_cascade_state` / `set_turn_phase`. The keeper lifecycle has a known incident class — `keeper_registry.ml:721 (2026-05-08)` raised `Assert_failure` from a sparse FSM match. The cascade / turn_phase validators are the next frontier of the same risk.

### 2.4 Caller fan-out

| Function | Production callers | Test callers | Total |
|---|---|---|---|
| `set_turn_cascade_state` | 4 (`keeper_unified_turn.ml` ×2, `keeper_run_tools.ml` ×2) | 12+ | ~16 |
| `set_turn_phase` | TBD (audit) | TBD | TBD |
| `validate_cascade_transition` | 0 (test-only) | 5+ | 5+ |
| `validate_turn_phase_transition` | 0 (test-only) | 4+ | 4+ |

A naive single-PR refactor of `set_turn_cascade_state`'s caller chain hits the **A1 abort signal** (>150 LOC impl) of `~/me/.claude/plans/fuzzy-twirling-chipmunk.md`. The work must be phased.

## 3. Goal

For both cascade and turn_phase sub-FSMs:

1. Replace runtime `invalid_arg` from forbidden transition pairs with **compile-time impossibility**.
2. Make the *valid transition set* a first-class value (GADT with one constructor per admitted pair), so adding a new variant or transition is a deliberate type-level commit.
3. Preserve caller ergonomics where possible — callers should not be forced to thread from-state explicitly through call chains unless they already know it.
4. Land the change in **3+ small PRs**, none exceeding 150 LOC impl, with each PR independently testable.

Out of scope for this RFC: compaction axis (separate audit needed — variants and topology not yet inventoried in this document).

## 4. Design

### 4.1 GADT pattern (precedent: existing `Decision_transition` module)

`lib/keeper/keeper_registry.ml` already defines `Decision_transition` GADT enumerating the 9 valid cross-state decision transitions (currently unused in production). The cascade axis mirrors this with **18 valid transitions**:

```ocaml
module Cascade_transition = struct
  type ('from, 'to_) t =
    (* idempotents (5) *)
    | Idle_to_idle : (cascade_idle, cascade_idle) t
    | Selecting_to_selecting : (cascade_selecting, cascade_selecting) t
    | Trying_to_trying : (cascade_trying, cascade_trying) t
    | Done_to_done : (cascade_done, cascade_done) t
    | Exhausted_to_exhausted : (cascade_exhausted, cascade_exhausted) t

    (* boot path (1) *)
    | Idle_to_selecting : (cascade_idle, cascade_selecting) t

    (* dispatch (1) *)
    | Selecting_to_trying : (cascade_selecting, cascade_trying) t

    (* retry / re-entry (3) *)
    | Selecting_to_idle : (cascade_selecting, cascade_idle) t
    | Trying_to_idle : (cascade_trying, cascade_idle) t
    | Trying_to_selecting : (cascade_trying, cascade_selecting) t

    (* completion / exhaustion (2) *)
    | Trying_to_done : (cascade_trying, cascade_done) t
    | Trying_to_exhausted : (cascade_trying, cascade_exhausted) t

    (* compaction-driven retry (6) *)
    | Done_to_idle : (cascade_done, cascade_idle) t
    | Done_to_selecting : (cascade_done, cascade_selecting) t
    | Done_to_trying : (cascade_done, cascade_trying) t
    | Exhausted_to_idle : (cascade_exhausted, cascade_idle) t
    | Exhausted_to_selecting : (cascade_exhausted, cascade_selecting) t
    | Exhausted_to_trying : (cascade_exhausted, cascade_trying) t
end
```

A similar `Turn_phase_transition` module enumerates valid turn-phase pairs.

### 4.2 Caller adapter — preserve `set_turn_cascade_state` ergonomics

Forcing every caller to construct a `Cascade_transition.t` value would break the "target-only" pattern that 16 call sites currently rely on. Instead:

```ocaml
(* set_turn_cascade_state stays target-only at the API surface *)
val set_turn_cascade_state :
  base_path:string -> string -> packed_cascade_state -> unit

(* Internal: read current state, construct the transition GADT.
   If the (from, target) pair is not representable in Cascade_transition.t,
   the internal helper is *type-unreachable* — meaning, by spec invariant,
   it cannot happen.  When it does (spec violation by a future caller), we
   surface a typed [transition_spec_violation] error instead of invalid_arg. *)
val resolve_cascade_transition :
  from:packed_cascade_state -> target:packed_cascade_state ->
  (packed_cascade_transition, cascade_transition_spec_violation) result
```

Where `cascade_transition_spec_violation` is a typed sum capturing each forbidden pair as a named constructor, eliminating string-based diagnostic messages.

### 4.3 Validator becomes documentation fixture

`validate_cascade_transition` becomes a compile-time fixture (same role as PR #14893 made `validate_decision_transition`): an explicit 18-pair match returning `()`, with no `invalid_arg`. Forbidden pairs are unrepresentable in the GADT.

### 4.4 Compaction axis (out of scope)

Compaction has a separate transition matrix (`compaction_accumulating`, `compaction_compacting`, etc.). A separate inventory PR audits its valid pairs and forbidden set before extending this RFC.

## 5. Migration plan

### Phase 1 — Cascade_transition GADT introduction (no behavior change)

- Define `Cascade_transition.t` GADT in `keeper_registry.ml`
- Implement `resolve_cascade_transition` (returns `Result.t` typed error)
- Existing `validate_cascade_transition` left unchanged
- Tests: GADT exhaustivity check (compile-time)
- LOC: ~80
- Risk: low (additive)

### Phase 2 — `set_turn_cascade_state` internal dispatch via GADT

- Internal implementation reads `obs.cascade_state`, calls `resolve_cascade_transition`, dispatches via GADT match
- On `Error spec_violation`: emit typed error (no `invalid_arg`)
- External API signature unchanged
- LOC: ~50
- Risk: medium (internal logic change in hot path; covered by existing tests)

### Phase 3 — `validate_cascade_transition` compile-time fixture

- Refactor function body to 18-pair `()` match (same shape as #14893 for decision)
- Update tests: delete `test_invalid_cascade_transitions` and `test_cascade_message_includes_labels`
- LOC: ~70
- Risk: low (test surface change consistent with #14893 precedent)

### Phase 4 — Turn_phase_transition GADT (parallel to Phase 1-3 for turn_phase axis)

Same 3-phase structure applied to `turn_phase`. Separate sub-PRs because the variant count is larger and the matrix shape differs.

### Phase 5 — Compaction axis audit (separate amendment)

Inventory `compaction_stage` variants + transition matrix. Decide whether the same pattern applies.

## 6. Risks

### 6.1 GADT introduces complexity

GADTs are an advanced OCaml feature. Future maintainers without GADT familiarity may misunderstand the pattern. Mitigation: each GADT module has docstring linking back to this RFC + to `Decision_transition` (precedent module). The 18-pair enumeration is more transparent than the witness-type pattern alone.

### 6.2 `resolve_cascade_transition`'s `Error` case at runtime

Even with GADT, runtime can still hit spec violations if a future code change creates a forbidden pair (the type system doesn't prevent it — only documents the contract). Difference from `invalid_arg`: the error path is *typed* and *catchable* by the caller. Production behavior unchanged (still aborts), but the typed error gives observability.

### 6.3 Test deletion concerns

Phase 3 deletes runtime-raise tests because the contract moves to the type system. Same pattern as PR #14893 — well-documented precedent. Reviewers should not require test preservation when the test cannot compile against the new signature.

### 6.4 Caller fan-out underestimation

The audit in §2.4 counted explicit `set_turn_cascade_state` calls. There may be indirect callers via helpers (e.g., `prepare_turn_retry_after_compaction`) not yet enumerated. Phase 1 begins with a complete `rg` sweep before any signature change.

## 7. Acceptance criteria

- **R-1**: `cascade_state` axis has 0 `invalid_arg` sites in `lib/`
- **R-2**: `turn_phase` axis has 0 `invalid_arg` sites in `lib/`
- **R-3**: All `cascade_state` valid transitions are first-class GADT constructors
- **R-4**: Adding a new `cascade_state` variant requires editing `Cascade_transition.t` and triggers Warning 8 at all match sites
- **R-5**: Existing test coverage is preserved or replaced by compile-time enforcement (no behavior regression)
- **R-6**: Phase 1 + Phase 2 + Phase 3 + Phase 4 each ship in independent PRs, each <150 LOC impl

## 8. Open questions

1. **OQ-1**: Should `Compaction_transition` GADT be added in this RFC or deferred? — Recommendation: defer to amendment after Phase 1-4 lands.
2. **OQ-2**: `resolve_*_transition` returns `Result.t` — does the typed error variant suffice, or should it carry the violated *invariant identifier* (e.g., TLA+ action name)? — Recommendation: start with simple typed variant, escalate if TLA+ trace integration becomes useful.
3. **OQ-3**: Should the existing `Decision_transition` GADT also be activated (PR-7 of this RFC) for symmetry, or left as standalone documentation? — Recommendation: defer; #14887 already closed the decision axis via input refinement, and GADT activation would force from-state threading without semantic gain.

## 9. Precedent + references

- **PR #14887** (`fix(keeper_registry): make set_turn_decision_stage's forbidden _to_undecided unrepresentable`) — decision-axis input refinement pattern.
- **PR #14893** (`refactor(keeper_registry): make validate_decision_transition compile-time enforced`) — decision-axis validator → compile-time fixture pattern.
- **`Decision_transition` GADT** (lib/keeper/keeper_registry.ml:349) — existing GADT pattern, unused, serves as template for `Cascade_transition` and `Turn_phase_transition`.
- **RFC-0003** (Keeper Composite Lifecycle Observer) — defines the 4-axis composite FSM.
- **RFC-0039** (Keeper Turn FSM — Streaming Escape & Cross-Axis Synchronization) — turn_phase axis context.
- **RFC-0042** (Closed sum type for keeper turn terminal code) — closed-sum enforcement precedent in adjacent surface.
- **CLAUDE.md `software-development.md` §AI 코드 생성 안티패턴 §4** — FSM Sparse Match anti-pattern; this RFC closes a generalisation of it.
- **Alexis King "Parse, don't validate"** — `software-development.md` §Coding Principle; "make illegal states unrepresentable".
