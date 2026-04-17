# FSM Spec ↔ Code Drift Audit (LT-15)

Neutral diff between TLA+ specs, OCaml types, and the composite observer projection for the keeper FSM axes, plus disposition of unpaired specs.

**Scope**: `specs/keeper-state-machine/` vs `lib/keeper/` as of commit `886abd2cc`. Post-audit update on 2026-04-17 folds in LT-16-KCB Phases 1–3 and promotes the circuit-breaker candidate to a landed 6th axis.

**Verdict**: 4 of 5 original axes align exactly. 1 axis (KSM) carries a **documented lossy projection** at the observer layer. The newly admitted 6th axis (KCB) has its **own kind of drift** — snapshot-observability does not match the spec's classical state set — and the landed implementation renders the 3 observable states only (see §3 and §5). 4 specs are unpaired in code; 2 have disposition decisions.

---

## 1. Per-axis state set diff

### KSM — Keeper State Machine

| Layer | Source                                              | States                                                                                                          | Count |
| ----- | --------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- | ----- |
| Spec  | `KeeperStateMachine.tla`                            | Offline, Running, Failing, Overflowed, Compacting, HandingOff, Draining, Paused, Stopped, Crashed, Restarting, Dead | 12    |
| Code  | `keeper_state_machine.mli:20` (`type phase`)        | same 12                                                                                                         | 12    |
| Observer | `keeper_composite_observer.mli:28` (`type ksm_phase`) | Ksm_running, Ksm_failing, Ksm_overflowed, Ksm_compacting, Ksm_handing_off, Ksm_draining, **Ksm_stable**       | 7     |

**Drift kind**: *intentional lossy projection*. Observer collapses 6 "stable" phases (Paused, Stopped, Crashed, Offline, Restarting, Dead) into a single `Ksm_stable`. Documented in `keeper_composite_observer.mli:22-27`:

> This is intentionally not the full `Keeper_state_machine.phase` domain: the composite observer collapses turn-external phases into `Ksm_stable` so the state set stays aligned with the observer TLA+ model.

**Impact for LT-16 matrix**: operator looking at a `Ksm_stable` cell cannot distinguish *Paused* (operator intent) from *Dead* (terminal) from *Offline* (never started). These are semantically very different failure modes.

**Recommendation**: keep `ksm_phase` in the observer projection, but **do not use it as the matrix column source**. Matrix should read `Keeper_state_machine.phase` directly (12 states) and apply a color grouping (stable=gray, transient=amber, error=red). Observer's 7-state projection is a separate TLA+ alignment artifact, not a UX artifact.

---

### KTC — Keeper Turn Cycle

| Layer | Source                                                  | States                                             | Count |
| ----- | ------------------------------------------------------- | -------------------------------------------------- | ----- |
| Spec  | `KeeperCascadeLifecycle.tla:33`, `KeeperCompactionLifecycle.tla:30` | `{"idle", "prompting", "executing", "compacting", "finalizing"}` | 5     |
| Code  | `keeper_registry.mli:42` (`type turn_phase`)            | `Turn_idle \| Turn_prompting \| ... \| Turn_finalizing` | 5     |

**Drift kind**: none. Prefix `Turn_` is an OCaml naming convention; JSON schema at `dashboard/src/api/schemas/keeper-composite.ts` normalizes to bare string. ✅

**Note**: `KeeperCompactionLifecycle.tla:30` declares `TurnPhaseSet` without `"finalizing"` (4 states), using the cascade spec's 5-state set via `EXTENDS`. Confirmed consistent at model-check time; the spec simply doesn't need `finalizing` for compaction reasoning.

---

### KDP — Keeper Decision Pipeline

| Layer | Source                                                  | States                                                        | Count |
| ----- | ------------------------------------------------------- | ------------------------------------------------------------- | ----- |
| Spec  | `KeeperDecisionPipeline.tla:27`                         | `{"undecided", "guard_ok", "gate_rejected", "tool_policy_selected"}` | 4     |
| Code  | `keeper_registry.mli:49` (`type decision_stage`)        | `Decision_undecided \| Decision_guard_ok \| Decision_gate_rejected \| Decision_tool_policy_selected` | 4     |

**Drift kind**: none. ✅

---

### KCL — Keeper Cascade Lifecycle

| Layer | Source                                                  | States                                                              | Count |
| ----- | ------------------------------------------------------- | ------------------------------------------------------------------- | ----- |
| Spec  | `KeeperCascadeLifecycle.tla:35`                         | `{"idle", "selecting", "trying", "done", "exhausted"}`              | 5     |
| Code  | `keeper_registry.mli:55` (`type cascade_state`)         | `Cascade_idle \| Cascade_selecting \| Cascade_trying \| Cascade_done \| Cascade_exhausted` | 5     |

**Drift kind**: none. ✅

---

### KMC — Keeper Memory Compaction

| Layer | Source                                                  | States                                           | Count |
| ----- | ------------------------------------------------------- | ------------------------------------------------ | ----- |
| Spec  | `KeeperCompactionLifecycle.tla:33`                      | `{"accumulating", "compacting", "done"}`         | 3     |
| Code  | `keeper_registry.mli:62` (`type compaction_stage`)      | `Compaction_accumulating \| Compaction_compacting \| Compaction_done` | 3     |

**Drift kind**: none. ✅

---

## 2. Unpaired specs (spec exists, no OCaml FSM type)

| Spec                        | What it models                                    | Code touchpoint (exists?)                          | Recommendation                                                                  |
| --------------------------- | ------------------------------------------------- | -------------------------------------------------- | ------------------------------------------------------------------------------- |
| `HebbianLearning`           | Trait drift under reinforcement                   | `lib/keeper/social_model/` — records, not an FSM   | **Retire spec to docs/**. No reactive state machine in the code; spec predates refactor. Keep as `docs/research/` reference. |
| `SessionRegistryGhost`      | Session registry eviction-race safety             | `lib/session/` — ad-hoc invariants, no FSM type    | **Formalize**. Add `type session_state = Active \| Evicting \| Evicted` mirroring the spec. Separate PR, not this cycle. |
| `DispatchHookChain`         | Hook execution ordering                           | `lib/dispatch_hook/` — list-based dispatch         | **Demote to invariant test**. The chain is a list, not an FSM; model-checker tests its invariants as properties. Convert to alcotest property test. |
| `DashboardCacheStampede`    | Cache invalidation race                           | `lib/server/` — single cache per route, no FSM     | **Retire spec**. The stampede scenario was fixed architecturally (per-route single-flight); spec is no longer load-bearing. Archive. |
| `KeeperOASAdvanced_TTrace_*`| Counterexample trace artifact                     | generated                                          | Already a build artifact; leave alone.                                          |

---

## 3. Candidate axes not currently on the matrix

Spec+code pair exists, but `KeeperCompositeLifecycle.tla` does not cross them with the core axes. Evaluate for admission as an additional matrix column.

| Candidate                      | Spec                                | Code                                                | States                                          | Verdict                                                                  |
| ------------------------------ | ----------------------------------- | --------------------------------------------------- | ----------------------------------------------- | ------------------------------------------------------------------------ |
| KCB — Circuit breaker          | `KeeperCircuitBreaker.tla`          | `keeper_failure_circuit_breaker.ml`                 | **Observable: clean, warning, cooling.** `tripped` is unobservable because the mutator resets `consecutive_count` during the trip transition. The spec's `Closed / Open / Half_open` triple does not survive the counter-based implementation as-is — `Open` is a transient step inside `record_failure`, not a stable state. | **Admitted as column 6** (LT-16-KCB Phase 1–3, 2026-04-17). Matrix, flowchart, and drift-audit all updated to the 3 observable states. `tripped` is marked with a dashed edge in the Mermaid panel to acknowledge the unobservable transition. |
| KCF — Campaign lifecycle       | `KeeperCampaignLifecycle.tla`       | `keeper_campaign_fsm.mli`                           | Bootstrapping, Claiming_task, Advancing, …      | **Defer.** Redundant with KDP for most operational decisions; matrix is already wide.       |
| KSM-Ledger — Magentic ledger   | `KeeperSocialModelMagenticLedger.tla` | `keeper_social_model_magentic_ledger_fsm.ml`      | Advancing, Reactive, …                          | **Defer.** Social-model signal, not an operational one; separate panel, not a core axis.   |

---

## 4. 6-place edit contract reaffirmed

Any addition/rename/removal on an axis-state must land in all six places in the **same PR**:

1. TLA+ `CONSTANTS` / `*Set ==` in `specs/keeper-state-machine/<Axis>.tla`.
2. Buggy companion `.cfg` if applicable.
3. OCaml variant in `lib/keeper/keeper_registry.ml(i)` or `keeper_state_machine.ml(i)`.
4. Observer re-export in `keeper_composite_observer.ml(i)` (if on the composite).
5. Schema `fallback()` union in `dashboard/src/api/schemas/keeper-composite.ts`.
6. Display map in `dashboard/src/components/fsm-hub-types.ts:displayState` + matrix color map in `fleet-fsm-matrix.ts` (landing in LT-16).

A CI rule enforcing this is out of scope for LT-15 but is the right follow-up (Doc Truth / Spec Truth check already exists for a different surface — this one would be "State Truth").

---

## 5. Conclusion

- **4 of 5 core axes are clean.** KTC/KDP/KCL/KMC are 1:1 between TLA+ and OCaml; the JSON schema handles prefix normalization.
- **1 axis carries a documented lossy projection.** `ksm_phase` collapses 6 OCaml phases into `Ksm_stable`. This is **not** a bug, but it is a UX constraint: the matrix should bypass the observer projection for KSM and consume `Keeper_state_machine.phase` directly (12 states with semantic color grouping).
- **4 unpaired specs** resolved: 2 retire, 1 formalize later, 1 demote to property test.
- **1 candidate axis** (circuit breaker) admitted as matrix column 6 and landed end-to-end through LT-16-KCB Phases 1–3 (#7793 / #7801 / #7822).

### Post-audit update (2026-04-17)

LT-16-KCB Phase 1 discovered that the KCB spec does not translate 1:1 to the implementation: the classical `Closed / Open / Half_open` triple names states that are either *unobservable at snapshot time* (`Open` = `tripped`, reset in the same critical section) or do not exist in the counter-based OCaml model. The landed axis therefore uses the **observable state set** (`clean / warning / cooling`) and the Mermaid flowchart notes the unobservable transition with a dashed edge.

This is the first axis in the matrix where the spec **state set disagreed with what a fleet-level observer can actually see**, and the drift audit checklist should be extended in the next iteration to include a "snapshot-observability" column per state, so the same trap does not hide inside future admissions (KCF, KSM-Ledger).

No code change in this PR. Next tick (T+3) is **LT-13**: wire `InvariantViolationCounts` to a Prometheus counter + alert rule + Grafana panel.

## 6. References

- `specs/keeper-state-machine/KeeperCompositeLifecycle.tla` — the joint spec.
- `lib/keeper/keeper_composite_observer.mli` — authoritative projection contract.
- `docs/observability/composite-fsm-matrix-design.md` (LT-12) — downstream design this audit feeds into.
- `docs/observability/cascade-metrics.md` — pre-existing 5-surface consistency pattern this 6-place contract extends.
