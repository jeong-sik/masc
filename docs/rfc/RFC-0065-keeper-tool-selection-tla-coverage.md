# RFC-0065 — Keeper Tool Selection Lifecycle: TLA+ Coverage Extension

**Status**: Draft
**Author**: jeong-sik (with Claude Opus 4.7)
**Date**: 2026-05-11
**Supersedes**: —
**Related**:
- RFC-0056 (incremental sub-library extraction) — G1–G5 gate baseline (§3.1), reused here as the *spec acceptance* gate
- RFC-0062 (typed `Tool_result.t` + typed `Sdk_*` blocker class) — Phase 0 produced the typed `blocker_class` enum that the new specs reason over
- PR #14613 (Track A — `KeeperRolloverDecision.tla` shipped) — this RFC's predecessor; covers Stage 4 *rollover gate* only

---

## 1. Problem

The Keeper Tool Selection lifecycle decomposes into five sequential stages:

```
Stage 0  Admission     → Stage 1  Tool Surface  → Stage 2  Cascade Attempt
                                                  → Stage 3  Tool Execution
                                                  → Stage 4  Post-Turn
```

TLA+ coverage audit at `origin/main` HEAD `f97b088f3` (post-#14613):

| Stage | OCaml seam | TLA+ coverage today | Bug-model pair |
|---|---|---|---|
| 0 Admission | `keeper_admission_router` + `keeper_turn_slot` | KeeperAdmissionLiveness (387 LOC) — token bucket + WFQ outcomes | yes (3 cfgs) |
| 1 Tool Surface | `keeper_run_tools.compute_tool_surface` (lines 628–970, 11 transforms) | **None** — runtime `Keeper_tool_surface_mismatch` is the only invariant | — |
| 2 Cascade Attempt FSM | `cascade_fsm.ml::decide` + `keeper_turn_driver::try_cascade` | KeeperCascadeRouting (365 LOC) models routing as *outcome predicates*, NOT as explicit FSM states | partial (routing only) |
| 3 Tool Execution | `keeper_exec_tools` + `keeper_tool_alias` | KeeperTurnCycle subsumes via `Awaiting_tool_result` phase | partial |
| 4 Post-Turn orchestration | `keeper_post_turn` + `keeper_rollover` + `keeper_status_bridge` | KeeperRolloverDecision (#14613) covers blocker_class→rollover gate **only** | partial (rollover only) |

`find specs/keeper-state-machine -name "*.tla" | wc -l` = 31. Three structural gaps remain.

### 1.1 Stage 1 gap — `compute_tool_surface`

`keeper_run_tools.ml:628-970` runs an 11-step transform every turn:

1. preset/custom allowlist resolution
2. alias canonicalize + core_always_tools union
3. discovered tools decay
4. BM25 deterministic prefilter
5. (optional) LLM TopK rerank
6. `merge_tool_selection_boundary` (4-source merge)
7. required-tool reconciliation
8. affordance tool injection
9. `Tool_op.compose` overlay + `validate_allow_list`
10. fallback floor (when empty)
11. last-turn safety intersect → passive loop strip → max-tools truncate → `Keeper_tool_surface_mismatch` guard

There is no model-checking-time invariant. `Keeper_tool_surface_mismatch` (line 998-1011) is *runtime*. If a refactor breaks the guarantee that `required ⊆ all_allowed`, TLC does not catch it.

### 1.2 Stage 2 gap — Cascade Attempt FSM

`cascade_fsm.ml::decide` returns one of `Accept | Accept_on_exhaustion | Try_next | Exhausted`. KeeperCascadeRouting.tla treats these as *outcome predicates* (provider selection result), not as states of an explicit attempt FSM. Two structural properties are unmodeled:

- **Hard-quota override** (`keeper_turn_driver.ml:657-669`) forces `Exhausted` *bypassing* `Cascade_fsm.decide`. The override is correct (hard quotas are non-cascadeable by definition) but invisible to the model checker — a future refactor that routes hard quotas through `decide` and relies on cooldown would not be caught.
- **Semaphore retention across tiers** (`keeper_turn_slot.ml::with_keeper_turn_slot`) holds one slot for the *full* `try_cascade` recursion. A future split that releases between tiers (well-intentioned for fairness) would silently break fleet starvation guarantees.

### 1.3 Stage 4 gap — Post-Turn orchestration

PR #14613 (Track A) shipped `KeeperRolloverDecision.tla` covering the typed `blocker_class → rollover_gate_decision` transition. The *orchestration* is not covered:

```
[turn ends]
  → keeper_post_turn::compaction_decision
    → keeper_rollover::classify_rollover_gate     (covered: #14613)
    → append_lineage_artifacts_best_effort        (covered: KeeperGenerationLineage)
    → apply_autonomous_wirein (A5)
    → apply_resilience_wirein (A6)
    → apply_tool_emission_wirein (K4b)
    → apply_multimodal_wirein (K1)
    → checkpoint persist
[turn end]
```

Six non-rollover post-turn callbacks fire in a *pinned order* (`keeper_post_turn.ml:640-647` documents the order in a comment). No spec asserts the ordering. A future PR that reorders A6 before A5 would compile and pass tests but silently violate the documented invariant.

### 1.4 Correspondence harness gap

Memory `reference_keeper_state_machine_specs_consolidation_status` P5 has been OPEN since 2026-04-29. There is no automated harness that:

- replays a TLC-emitted trace through OCaml `keeper_state_machine.ml`,
- asserts every allowed TLA+ transition has a corresponding OCaml transition,
- asserts every OCaml transition appears in some TLA+ spec.

Spec drift relative to OCaml is currently detected only by humans reading both.

---

## 2. Non-Goals

- **Not a rewrite of existing specs.** KeeperAdmissionLiveness, KeeperCascadeRouting, KeeperCompositeLifecycle, KeeperGenerationLineage remain authoritative for their stages. This RFC only adds three new specs and one harness.
- **Not a refinement proof.** TLC checks invariants and bounded liveness, not full state-space refinement against OCaml. The correspondence harness (§3.6) is *trace-replay*, not refinement.
- **Not RFC-0058 territory.** Cascade routing (RFC-0058 Phase 5.1+) continues to evolve. This RFC's Stage 2 spec models the orthogonal *attempt FSM* axis (states + transitions), not provider selection.
- **Not a CompositeLifecycle restructure.** New specs join as observer sub-FSMs (additive). Existing joint invariants stay unchanged.

---

## 3. Proposal

### 3.1 Acceptance gate (G1–G5, adapted from RFC-0056 §3.1)

A new TLA+ spec is integrated into KeeperCompositeLifecycle observer if and only if all five gates pass on the proposed final cfg pair:

| Gate | Definition | Verification |
|---|---|---|
| **G1: Clean PASS** | `tlc -config <Spec>.cfg <Spec>.tla` exits 0 with no invariant violation, no deadlock, bounded state space ≤ 1M states. | TLC stdout + `make -C specs check-clean`. |
| **G2: Buggy VIOLATED** | `tlc -config <Spec>-buggy.cfg <Spec>.tla` reports invariant violation in ≤ MaxSteps. Buggy cfg must model the *class* of bug we want to prevent (CLAUDE.md §TLA+ Bug Model), not a single instance. | TLC reports `Invariant <Name> is violated`. |
| **G3: Provider opacity** | The spec and both cfgs contain zero literal provider identifiers (`anthropic`, `openai`, `claude`, `gpt`, `gemini`, `sonnet`, `opus`, `haiku`). Provider symbols are abstract (`Provider_1`, `Tier_A`, etc.). | `rg -i '<provider-regex>' <Spec>.tla <Spec>*.cfg` → 0 hits. |
| **G4: Observer integration** | Adding the new sub-FSM to `KeeperCompositeLifecycle.tla` keeps all existing joint invariants passing. The new sub-FSM exports a small projection (≤ 8 ghost variables) consumed by Composite. | TLC on `KeeperCompositeLifecycle.cfg` + `-buggy-*.cfg` pairs. |
| **G5: OCaml correspondence** | Every spec state has a documented OCaml seam (file:line range). `test_keeper_ocaml_tla_correspondence.ml` (§3.6) maps each spec transition to a matching OCaml transition; missing mapping fails the test. | Alcotest. |

Failure of any gate → reject. No `WORKAROUND:` label, no integration deferral. Reject means the candidate is not yet ready for the Composite observer; rework before retry.

### 3.2 New specs (B1–B3)

#### 3.2.1 B1: `KeeperCascadeAttemptFSM.tla` — Stage 2

**Scope**: model `cascade_fsm.ml::decide` as an explicit state machine, not just outcomes.

**States**:
```
Idle → Attempting → Awaiting_response →
    { Success                    → Idle
    | Try_next   → Attempting    (recursive; same slot retained)
    | Exhausted_normal           → Terminal_fail
    | Exhausted_hard_quota       → Terminal_fail }
```

**Ghost projection for Composite**: `attempt_phase ∈ {idle, attempting, awaiting, terminal_ok, terminal_fail}`, `tier_index ∈ 0..N`.

**Invariants**:
- `SlotReleasedOnTerminal` — once `attempt_phase = terminal_*`, the abstract slot count returns to baseline (mirrors `with_keeper_turn_slot` release).
- `HardQuotaTerminalImmediate` — when `Exhausted_hard_quota` fires, `tier_index` does not advance (no fallthrough to next tier).
- `TryNextProgresses` — `Try_next` strictly increments `tier_index` (no infinite loop without exhaustion).

**Bug actions** (each maps to one historical risk):

| `BugAction` | OCaml regression it models | Invariant it violates |
|---|---|---|
| `HardQuotaBypass` | the override at `keeper_turn_driver.ml:657-669` is removed and quota errors route through `decide` → tier fallback consumes additional providers | `HardQuotaTerminalImmediate` |
| `SemaphoreReleaseBetweenTiers` | `with_keeper_turn_slot` releases between tiers — well-intentioned for fairness, breaks intra-cascade slot retention | `SlotReleasedOnTerminal` (becomes vacuously true mid-cascade, then re-violated on terminal) |
| `TryNextLoopsForever` | `decide` returns `Try_next` with `tier_index` unchanged (off-by-one in tier walker) | `TryNextProgresses` |

LOC budget: ~220.

#### 3.2.2 B2: `KeeperToolSurface.tla` — Stage 1

**Scope**: model the 11-step `compute_tool_surface` transform as an ordered pipeline.

**Pipeline (abstract)**:
```
allowlist → universe → discovered → prefiltered → reranked → merged →
required → affordance → overlay_composed → fallback_floored →
last_turn_safe → passive_filtered → truncated → emitted
```

Each stage is a set transformation on `Tools` (the universe of tool names). Required tools are tracked as a separate set `Required`.

**Invariants**:
- `RequiredSubsetEmitted` — equivalent of `keeper_run_tools.ml:998-1011` mismatch guard at model-checking time: `Required ⊆ emitted ∨ Required ∩ AlwaysAffordanceless ≠ ∅` (the surface-mismatch branch must fire).
- `LastTurnSafeMonotone` — the last-turn safety filter only *removes* tools, never adds.
- `FallbackFloorOnlyWhenEmpty` — the floor injects tools only when the upstream pipeline emits an empty set (covers `keeper_run_tools.ml:819-825`).
- `MaxToolsCap` — `|emitted| ≤ MaxToolsPerTurn`, and the cap preserves all `Required` first.

**Bug actions**:

| `BugAction` | OCaml regression it models | Invariant it violates |
|---|---|---|
| `RequiredEscapesValidate` | `validate_allow_list` is removed from the overlay compose path → required tools not in the universe leak through | `RequiredSubsetEmitted` |
| `LastTurnSafeAdds` | the last-turn safety filter is implemented as a union instead of an intersect | `LastTurnSafeMonotone` |
| `FallbackFloorAlwaysOn` | floor fires unconditionally (defense-in-depth → permissive default; observed historically as the "always show floor" suspicion) | `FallbackFloorOnlyWhenEmpty` |
| `MaxToolsDropsRequired` | truncation removes required tools instead of optional ones | `MaxToolsCap` (Required-preservation conjunct) |

LOC budget: ~260.

#### 3.2.3 B3: `KeeperPostTurnOrchestration.tla` — Stage 4

**Scope**: model the post-turn pipeline ordering and the blocker_info stamping contract.

**Sequence**:
```
turn_ended
  → compaction_decision        ∈ {Applied(s), Blocked, Skipped(reason)}
  → blocker_info_stamped       ∈ {None, Some(klass)}
  → rollover_decision          (delegates to KeeperRolloverDecision via observer)
  → wirein_autonomous (A5)
  → wirein_resilience (A6)
  → wirein_tool_emission (K4b)
  → wirein_multimodal (K1)
  → checkpoint_persisted
```

**Ghost projection for Composite**: `post_turn_phase`, `wirein_order : Seq(Atom)`, `blocker_stamped_before_rollover : Bool`.

**Invariants**:
- `WireinOrderPinned` — `wirein_order = ⟨A5, A6, K4b, K1⟩` for every turn (pinned by comment at `keeper_post_turn.ml:640-647`; never observed otherwise).
- `BlockerStampedBeforeRollover` — when `rollover_decision = Go(_)`, `blocker_info_stamped` was set on the same turn or carried from a prior `Proactive_error` outcome. Closes the producer half of the stamp gap (Track A closed the consumer half).
- `CheckpointPersistedAfterWirein` — `checkpoint_persisted` strictly follows the K1 phase; no parallel commit.
- `LineageAppendedOnRolloverGo` — when `rollover_decision = Go(_)`, the lineage artifact append fires before checkpoint persist.

**Bug actions**:

| `BugAction` | OCaml regression it models | Invariant it violates |
|---|---|---|
| `WireinOutOfOrder` | A6 fires before A5 (reorder pin removed) | `WireinOrderPinned` |
| `StampGap` | `blocker_info` is stamped *only* in the detail/text field, klass remains None (the historical 4/14 keepers case, closed for *rollover-fire* by Track A but not for *every* downstream consumer) | `BlockerStampedBeforeRollover` |
| `CheckpointBeforeWirein` | checkpoint persisted at the top of post_turn before A5–K1 mutate working_context | `CheckpointPersistedAfterWirein` |
| `LineageAfterCheckpoint` | lineage append is moved to after checkpoint persist (well-intentioned ordering tweak) | `LineageAppendedOnRolloverGo` |

LOC budget: ~200.

### 3.3 Correspondence harness — `test/test_keeper_ocaml_tla_correspondence.ml`

**Scope**: trace-replay verification.

**Inputs**:
- TLA+ traces emitted by TLC for each of B1/B2/B3 + the existing KeeperStateMachine, KeeperRolloverDecision, KeeperAdmissionLiveness clean cfgs.
- OCaml state-machine functions: `keeper_state_machine.ml::next`, `keeper_turn_fsm.ml::transition`, `cascade_fsm.ml::decide`, `keeper_rollover.ml::classify_rollover_gate`.

**Procedure**:
1. For each spec, generate trace via `tlc -dump trace.tla <Spec>.cfg <Spec>.tla` (bounded trace, MaxSteps ≤ 8).
2. Parse trace → sequence of `(state_before, action, state_after)` tuples.
3. For each tuple, invoke the corresponding OCaml function with the input state; assert output equals `state_after` (modulo projection — only the ghost variables are compared).
4. Test fails if any tuple is rejected by OCaml, or if any OCaml transition has no TLA+ tuple covering its `(input_class, output_class)` pair.

**Pass criterion**: trace-replay PASS for all clean cfgs; intentional regression in OCaml (e.g., catch-all `_ -> None`) causes test failure.

**Test budget**: ~400 LOC, including trace parser. Adapts the open-source `tla-trace-parser` pattern (no external deps; pure OCaml).

### 3.4 Observer integration into `KeeperCompositeLifecycle.tla`

Existing Composite spec observes 5 sub-FSMs (KSM, KTC, KDP, KMC, KCL) at 449 LOC. This RFC adds three:

```
KCompositeLifecycle EXTENDS
  ...
  KeeperCascadeAttemptFSM,      (* new *)
  KeeperToolSurface,            (* new *)
  KeeperPostTurnOrchestration   (* new *)
```

New joint invariants (one per pair of interest):

- `AttemptFSMRespectsAdmission` — when KeeperAdmissionLiveness denies admission, KeeperCascadeAttemptFSM cannot enter `Attempting`.
- `ToolSurfaceFeedsAttempt` — KeeperToolSurface's `emitted` is non-empty when KeeperCascadeAttemptFSM enters `Attempting` (no empty-surface attempt).
- `PostTurnConsumesAttempt` — KeeperPostTurnOrchestration begins only when KeeperCascadeAttemptFSM reaches a terminal state.

Joint invariants stay weak (predicates over projections) — no full product state space is enumerated.

---

## 4. Bug Model Pair Inventory

Total: 3 new specs × ~4 bug actions each = 12 bug invariants. Cataloged in §3.2 per spec.

Each bug action models a *class* of regression that has either been observed historically or is structurally one rename away. None model a specific commit; the spec is a defense against the *anti-pattern category*.

---

## 5. Migration Plan

Three phases, each in its own PR. Each PR self-contained (no cross-PR atomicity required because new specs are additive).

| Phase | Scope | Files | Estimated PR size |
|---|---|---|---|
| **5.1** | B1 (Cascade Attempt FSM) + observer wiring + correspondence harness scaffold (replays the existing KeeperStateMachine + KeeperRolloverDecision traces only — proves the harness works before adding new specs) | 3 spec/cfg + 1 harness `.ml` + 1 Composite observer edit | +400 LOC, –20 LOC |
| **5.2** | B2 (Tool Surface) + observer joint invariant `ToolSurfaceFeedsAttempt` + harness extension | 3 spec/cfg + Composite edit + harness extension | +350 LOC |
| **5.3** | B3 (Post-Turn Orchestration) + observer joint invariant `PostTurnConsumesAttempt` + harness extension + memory `reference_keeper_state_machine_specs_consolidation_status` P5 closed | 3 spec/cfg + Composite edit + harness extension + memory note edit | +280 LOC |

**Phase ordering rationale**: B1 first because it's the most actively-evolving area (RFC-0058 traffic). Adding the spec early catches drift sooner. B2 second because it's the largest LOC budget and benefits from the harness already proven on B1. B3 last because it depends on B1 reaching a terminal state (joint invariant `PostTurnConsumesAttempt`).

**Rollback path**: each PR reverts cleanly because:
- specs are new files (`git rm` reverts),
- Composite observer additions are conditional `IF spec_loaded THEN check_joint ELSE TRUE`,
- harness extensions are per-spec functions — removing the spec removes the call site.

---

## 6. Verification

### 6.1 Per-PR

- [ ] `tlc -config <Spec>.cfg <Spec>.tla` → no error (G1)
- [ ] `tlc -config <Spec>-buggy.cfg <Spec>.tla` → invariant violated (G2)
- [ ] `rg -i 'anthropic|openai|claude|gpt|gemini|sonnet|opus|haiku' <Spec>.tla <Spec>*.cfg` → 0 hits (G3)
- [ ] `tlc -config KeeperCompositeLifecycle.cfg KeeperCompositeLifecycle.tla` after new sub-FSM added → no error (G4)
- [ ] `dune runtest test/test_keeper_ocaml_tla_correspondence.ml` PASS (G5)
- [ ] `bash scripts/gen-tla-index.sh > specs/INDEX.md` and commit the regenerated index (drift-check CI)

### 6.2 RFC-level (this document)

- [x] All §1 measurements verified at HEAD `f97b088f3` (post-#14613)
- [x] G1-G5 gates inherit from RFC-0056 §3.1 (baseline)
- [x] Provider opacity invariant cross-references the architectural invariant pinned by Track A (PR #14613)
- [x] Bug actions enumerated per spec (§3.2)
- [x] Migration phases independent and rollback-clean (§5)

### 6.3 Done definition

This RFC is implementable when:

- A reviewer can read §1 and reproduce the measurements (`find specs/keeper-state-machine -name "*.tla" | wc -l` returns 31; `wc -l lib/keeper/keeper_run_tools.ml` ≥ 1500; etc.).
- The five gates in §3.1 are mechanical (every step is a shell command).
- Each phase in §5 fits in a single PR without the others.
- The correspondence harness in §3.3 has no external dependency beyond Alcotest + the existing TLC tooling already wired into CI (`scripts/tla-check.sh`).

---

## 7. Open questions

1. **Trace parser dependency choice**: §3.3 says "no external deps; pure OCaml". An alternative is to use a published `tla-trace-parser` library. If one becomes a published opam package during Phase 5.1, prefer that — but in-tree parser is fine.
2. **Composite cfg state-space blowup**: adding 3 observer projections may exceed the 1M-state bound. If so, Phase 5.1 includes a `MaxSteps` reduction in `KeeperCompositeLifecycle.cfg` (currently 8); falling back to 6 is acceptable. Smaller bound is reported in the PR body.
3. **Liveness vs safety**: this RFC only defines safety invariants per spec. Liveness (`<>` properties) for the attempt FSM (e.g., "every `Attempting` eventually reaches a terminal state") is deferred to a follow-up if KeeperReconcileLiveness coverage proves insufficient.

---

## 8. References

- RFC-0056 §3.1 — extraction gate G1-G5 (the gate format reused here)
- RFC-0062 — typed `blocker_class` enum (the type domain B3 reasons over)
- PR #14613 — Track A, `KeeperRolloverDecision.tla` (the predecessor spec)
- CLAUDE.md `software-development.md` §TLA+ Bug Model 패턴 — clean+buggy cfg convention
- CLAUDE.md `software-development.md` §AI 코드 생성 안티패턴 #4 — FSM Sparse Match (the catch-all this RFC's invariants forbid)
- Memory `reference_keeper_state_machine_specs_consolidation_status` (operator-local) — P5 OPEN item closed by §3.3
