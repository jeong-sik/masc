# TLA+ PPX Adoption Audit — 2026-04-30

> Status: First-pass audit. Surveys runtime PPX adoption against the 84-spec TLA+ surface.
> Author: Vincent (jeong-sik) with Claude
> Created: 2026-04-30
> Tracks: Q-P0-2 sibling (TLA+ specs gap audit chain, PR #12123 / #12132 / #12137)
> Related: PR #11377 (ppx_tla Cycle 2), PR #11696 (`[@@fsm_guard]` Cycle 43)

---

## 1. Two distinct PPX systems

The repo has **two TLA-related PPX systems**, with separate purposes and adoption profiles. The Q-P0-2 specs gap audit chain measured spec-side coverage; this audit measures **runtime side**.

### 1.1 `[@@deriving tla]` — variant↔symbol mapping

| Property | Value |
|---|---|
| Implementation | `ppx_tla/ppx_tla.ml` (675 LOC) |
| Generated symbols | `to_tla_symbol`, `all_symbols`, `all_states`, `is_terminal`, `is_active`, `is_idle`, etc. |
| Per-constructor attrs | `[@tla.symbol "explicit"]`, `[@tla.terminal]`, `[@tla.active]`, `[@tla.idle]`, `[@@tla.phantom_param]` |
| Goal | Eliminate maintenance cost of keeping OCaml variants in lock-step with TLA+ string literals. The OCaml type is SSOT |

### 1.2 `[@@fsm_guard "<bool-expr>"]` — runtime assertion + metric

| Property | Value |
|---|---|
| Implementation | `ppx_tla/ppx_tla.ml` + `lib/keeper/keeper_fsm_guard_runtime.{ml,mli}` (33 + 36 LOC) |
| Behaviour | Identity helper wrapping any value with `try assert(<expr>); v with Assert_failure -> incr counter; v` |
| Metric | `metric_fsm_guard_violation` (`lib/prometheus.mli:293`) |
| Runtime gate | `MASC_FSM_GUARD_ASSERT=1` re-raises (off by default — production records, doesn't crash) |

This is the canonical "spec-action as runtime invariant" hook documented in CLAUDE.md (`feedback_fsm_guard_identity_helper_counter_wrap_pattern`).

## 2. Adoption metrics

### 2.1 `[@@deriving tla]`

```bash
$ rg -n "deriving tla" lib/ | rg -v "(\* | \*\)"
lib/multimodal/artifact.ml:28
lib/keeper/keeper_turn_fsm.mli:58, lib/keeper/keeper_turn_fsm.ml:36
lib/autonomous/stimulus.mli:84, lib/autonomous/stimulus.ml:14
lib/autonomous/autonomous_phase.{mli:68,172, ml:30,107}
```

**4 unique modules**: `Multimodal.Artifact`, `Keeper.Keeper_turn_fsm`, `Autonomous.Stimulus`, `Autonomous.Autonomous_phase`. (7 file mentions; .mli + .ml + multiple type decls per module.)

| Module | Specs that should mirror it | Linked? |
|---|---|---|
| `Multimodal.Artifact` | `multimodal/MultimodalArtifact.tla` | YES |
| `Keeper_turn_fsm` | `keeper-turn-fsm/KeeperTurnFSM.tla` | YES |
| `Stimulus` | `autonomous/AutonomousLoop.tla` (covers stimulus indirectly) | partial |
| `Autonomous_phase` | `autonomous/AutonomousPhase.tla` | YES |

### 2.2 `[@@fsm_guard]`

```bash
$ rg -n "@@fsm_guard" lib/
lib/keeper/keeper_keepalive_signal.ml: 5 guards (turn_running, wakeup atomic, current_task_id)
lib/keeper/keeper_turn_helpers.ml:    3 guards (any_pending, channel selector, cycle_completed)
lib/keeper/keeper_turn_fsm.ml:        1 guard (require_active_state)
```

**3 lib files, 9 guard sites**. All inside `lib/keeper/`. No guards in `lib/server/`, `lib/dashboard/`, `lib/multimodal/`, `lib/autonomous/`, `lib/resilience/`, `lib/shared_audit/`.

## 3. Coverage assessment

| Domain | TLA spec count | `[@@deriving tla]` modules | `[@@fsm_guard]` sites | Coverage class |
|---|---|---|---|---|
| keeper-state-machine | 46 | 1 (Keeper_turn_fsm) | 9 | partial |
| boundary | 25 | 0 | 0 | **none** |
| bug-models | 23 | 0 | 0 | **none** (intentional — bug-models are negative) |
| autonomous | 2 | 2 (Stimulus, Autonomous_phase) | 0 | **deriving full**, **guard 0** |
| multimodal | 2 | 1 (Artifact) | 0 | **deriving partial**, **guard 0** |
| keeper-turn-fsm | 1 | 1 | 9 | full |
| keeper-fsm-guard | (no spec) | runtime + 9 sites | runtime + 9 sites | runtime-only |
| admission-queue, auth, checkpoint-trim, closure, masc-ecosystem, resilience, server-state, shared, social-state-cap, state-product, task-lifecycle | 14 | 0 | 0 | **none** |

**Aggregate**: of 84 specs, ~5 specs (6%) are runtime-instrumented via either PPX. boundary (25 specs) and the long tail (14 specs across 11 domains) have **zero** runtime↔spec link.

## 4. The drift problem

When a domain has a TLA spec but no PPX hook:
- Adding a new variant to the OCaml ADT does NOT regenerate the corresponding TLA `StateSet` literal.
- Adding a new transition in the OCaml `match` does NOT verify the spec's `Next` covers it.
- A documented `OCaml ↔ TLA+ mapping` comment (~20 specs have these in headers) is **manually maintained** and rots silently.

`scripts/ci/check-tla-variant-sync.sh` (62 LOC) tries to bridge this gap, but:
- It scans only `lib/keeper/keeper_types.ml` (not all variant types)
- It uses `rg` regex matching (not AST parsing), which is documented as "intentionally conservative"
- It produces **warnings only**, not gate failures

So the actual enforcement is: **PPX-instrumented domains drift-free; non-instrumented domains rely on manual review.**

## 5. Why not just `[@@deriving tla]` everything?

Adoption cost varies:
- **Low cost (recommend now)**: ADTs that already mirror a TLA `StateSet` (e.g. lifecycle phases). These get `to_tla_symbol` for free.
- **Medium cost**: ADTs with parameterised constructors (`Failed of failure_reason`). Supported via `[@tla.symbol]` but the mapping is one-way (TLA symbol exists for `Failed _`; reverse not generated).
- **High cost (defer)**: Records with nested fields, polymorphic types, GADTs. ppx_tla supports `[@@tla.phantom_param]` for some cases but not arbitrary structural mapping.
- **Not applicable**: bug-models (negative specs) — they assert *what should not happen*; runtime instrumentation is the wrong direction.

For the 14 zero-coverage domains, the right next step is **per-domain triage** (similar to Q-P0-2 Phase 3's RFC stubs), not blanket adoption.

## 6. `[@@fsm_guard]` adoption is a different question

`[@@fsm_guard]` instruments **transition guards**, not state names. Coverage gap = "places where a TLA `Next` predicate has a precondition that doesn't appear as an OCaml runtime check."

The 9 existing guards cover 3 keeper subsystems. Other keeper subsystems (`keeper_run_tools`, `keeper_context_core`, `keeper_guards`) have rich state machines but no guards. This is a separate adoption track from `[@@deriving tla]`.

## 7. Severity ranking

| Class | Severity | Rationale |
|---|---|---|
| 14 zero-coverage domains | **Medium** | Documented mappings rot silently; depends on manual review at PR time. Adding `[@@deriving tla]` per domain is bounded work. |
| `check-tla-variant-sync.sh` warn-only & narrow scope | Low–Medium | Heuristic; produces drift signal but doesn't gate. Could be tightened to AST-based once PPX coverage rises. |
| `[@@fsm_guard]` adoption gap in keeper subsystems | Low | Optional layer. Existing 9 guards in 3 files captured the highest-value invariants from `KeeperOASAdvanced` work. |
| boundary domain (25 specs, 0 hooks) | Medium | Largest unhooked surface. Spot-check whether boundary specs even have ADTs to derive — many model cross-domain protocols (e.g. cascade resolver) without a single OCaml type. |

## 8. Recommended ratchet (descriptive, not enforced)

```bash
# Strict (eventual)
ppx_deriving_tla_modules: count of lib/ modules with [@@deriving tla]
# Floor: 4 (current). Goal: monotonic increase.

ppx_fsm_guard_files: count of lib/ files using [@@fsm_guard]
# Floor: 3 (current). Goal: monotonic increase.

# Descriptive
domains_with_zero_ppx_link: count of TLA spec domains with 0 PPX-instrumented modules
# Floor: 14 (current). Goal: monotonic decrease.
```

Same enforcement discipline as the OAS chain: defer hard-gating until at least 2 follow-up PRs land, otherwise the floor enforces nothing meaningful. This is the same logic as the Q-P0-2 Phase 4 deferral.

## 9. Suggested next steps (out of scope)

1. **boundary domain spot-check** (1 cycle): pick 3 of the 25 boundary specs, identify whether they have a corresponding OCaml ADT. If yes → `[@@deriving tla]` candidate. If no → document why (cross-domain protocol with no single type owner).
2. **resilience domain `[@@deriving tla]`** (1 cycle): `Resilience.Degradation` has a 4-level lattice — perfect fit for `[@tla.terminal]` markers and TLA symbol generation. Existing `Resilience_outcome` module also.
3. **`check-tla-variant-sync.sh` upgrade** (1 cycle, deferred until PPX adoption rises): replace `rg` heuristic with AST parsing once enough modules carry `[@@deriving tla]` that `all_symbols` is the canonical source.
4. **`[@@fsm_guard]` extension to `keeper_run_tools`** (1 cycle, optional): the `KeeperRecoveryOrchestration` and `KeeperContractViolated` boundary specs already exist; their guard preconditions are candidates for runtime instrumentation.

## 10. References

- `ppx_tla/ppx_tla.ml` — 675 LOC, both PPX entry points
- `lib/keeper/keeper_fsm_guard_runtime.{ml,mli}` — 33 + 36 LOC runtime
- `scripts/ci/check-tla-variant-sync.sh` — 62 LOC heuristic 3-way sync
- `specs/INDEX.md` — auto-generated spec inventory (84 specs, 17 domains)
- PR #11377 — ppx_tla Cycle 2 (deriving foundation)
- PR #11696 — `[@@fsm_guard]` Cycle 43
- `docs/audit/TLA-SPECS-GAP-AUDIT-2026-04*.md` — sister audit chain (specs-side gap)
- `docs/audit/OAS-MASC-BOUNDARY-AUDIT-2026-04*.md` — same Phase 1→4 discipline applied to OAS boundary
- CLAUDE.md `TLA+ Bug Model 패턴` (specs side), `feedback_fsm_guard_identity_helper_counter_wrap_pattern` (runtime side)
- Memory: `feedback_self_confession_comments_must_be_measured` — applies here: don't trust "OCaml ↔ TLA+ mapping" comments alone; PPX is the measured equivalent.

*Audit date: 2026-04-30 / Phase 1 of N / docs-only / sister to Q-P0-2 specs chain*
