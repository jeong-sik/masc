# TLA+ Specs Gap Audit — Phase 3 (zero-coverage RFC index)

> Status: Phase 3 of N. Per-spec RFC stubs for the 8 zero-Bug-Model-coverage specs from Phase 1.
> Author: Vincent (jeong-sik) with Claude
> Created: 2026-04-30
> Tracks: Q-P0-2 follow-up
> Related: PR #12123 (Phase 1, MERGED), PR #12132 (Phase 2, Draft as of writing)

---

## 1. Why Phase 3 enumerates RFCs instead of writing buggy cfgs

Phase 1 §5 said:

> Each Bug Model needs a domain-specific BugAction describing a real production bug. […] Writing a buggy cfg without that domain knowledge produces *fake* Bug Models — an `assert false` in the BugAction would trip any invariant. The audit's role is to *flag the gap*, not to fabricate models.

Phase 3 honours that boundary: it does *not* write the buggy cfgs. It enumerates **what each Bug Model would need to model** so the work can fan out across follow-up PRs, each authored by someone with the domain context to pick a *realistic* `BugAction`.

The 8 specs are listed below in fan-out order, prioritised by hot-path proximity (autonomous loop and resilience interact with cascade orchestration; ecosystem/multimodal/shared specs are slower-moving).

## 2. RFC stubs

### RFC-Q2-1: AutonomousLoop bug model

| Field | Value |
|---|---|
| Spec | `specs/autonomous/AutonomousLoop.tla` (119 LOC) |
| Critical safety property | `TickOnlyDuringRunning`, `MetaPersistedAfterTick` |
| Subject of bug action | The autonomous tick must NOT mutate the keeper FSM phase |
| Suggested `BugAction` | `AutonomousTickFlipsKeeperPhase`: a tick action that, in addition to its meta update, also writes `keeper_phase' = "draining"` |
| Expected result | `TickOnlyDuringRunning` violated in ≤2 steps (start running → tick flips to draining → next tick fires while draining) |
| Owner | TBD |

### RFC-Q2-2: AutonomousPhase bug model

| Field | Value |
|---|---|
| Spec | `specs/autonomous/AutonomousPhase.tla` (95 LOC) |
| Critical safety property | `OnlyLegalTransitions`, `CurrentMatchesHead` |
| Subject of bug action | 19 legal transitions enforced by GADT in OCaml; spec asserts no illegal transitions reachable |
| Suggested `BugAction` | `IllegalTransition`: e.g. `idle → planning` (skipping perceiving/intending) |
| Expected result | `OnlyLegalTransitions` violated in 1 step |
| Owner | TBD |

### RFC-Q2-3: MASCEcosystem bug model

| Field | Value |
|---|---|
| Spec | `specs/masc-ecosystem/MASCEcosystem.tla` (119 LOC) |
| Critical safety property | (currently only `TypeOK` declared in cfg — first need a real safety inv) |
| Subject of bug action | Agent/keeper/persona/room interaction. A plausible bug: a keeper accepts a task while another agent has it claimed |
| Suggested `BugAction` | `DoubleClaim`: keeper sets `agent_tasks[k] = t` while `agent_tasks[a] = t` for some other `a` |
| Prerequisite | Add `AtMostOneAgentPerTask` invariant before adding the bug action — current cfg invariants are too weak to catch the bug |
| Owner | TBD |

### RFC-Q2-4: MultimodalArtifact bug model

| Field | Value |
|---|---|
| Spec | `specs/multimodal/MultimodalArtifact.tla` (204 LOC) |
| Critical safety property | provenance DAG well-formedness, kind/payload variant well-formedness |
| Subject of bug action | The runtime tracks artifact presence via map presence; spec models with `present : BOOLEAN`. A plausible bug: hydrator returns a `present=FALSE` placeholder as if it were realized |
| Suggested `BugAction` | `ReturnPlaceholderArtifact`: action that exposes a `present=FALSE` artifact through an output relation |
| Expected result | invariant on payload realization should fire |
| Owner | TBD |

### RFC-Q2-5: MultimodalHydrator bug model

| Field | Value |
|---|---|
| Spec | `specs/multimodal/MultimodalHydrator.tla` (110 LOC) |
| Critical safety property | DAG: no self-loop, no cycle, edge-set idempotence |
| Subject of bug action | `add_edge` is documented as idempotent and acyclic. Plausible bugs: idempotence break (re-adding bumps edge count), or cycle introduction (`add_edge from=X to=X` allowed) |
| Suggested `BugAction` | `AddSelfLoop`: relax the precondition guarding `from /= to` |
| Expected result | `NoSelfLoop` (would need to add to clean cfg first) violated in 1 step |
| Prerequisite | Promote DAG safety from spec text to cfg-level invariant |
| Owner | TBD |

### RFC-Q2-6: ResilienceDegradation bug model

| Field | Value |
|---|---|
| Spec | `specs/resilience/ResilienceDegradation.tla` (160 LOC) |
| Critical safety property | "L4 + Permanent must NEVER trigger Retry" (lattice monotonicity + fault-amplification guard) |
| Subject of bug action | Lattice monotonicity break — operator-authorised L4 transparently dropping to L1 |
| Suggested `BugAction` | `LatticeRegress`: `degradation_level' = "L1"` from any other state without explicit recovery |
| Expected result | monotonicity invariant violated in ≤1 step |
| Owner | TBD |

### RFC-Q2-7: ResilienceOutcome bug model

| Field | Value |
|---|---|
| Spec | `specs/resilience/ResilienceOutcome.tla` (161 LOC) |
| Critical safety property | confidence in [0,1]; `degradation_level` in [1,4] for PartialSuccess only; `completed`/`failed` artifact sets disjoint |
| Subject of bug action | A FullSuccess outcome carries a degradation_level field (currently invariant says PartialSuccess only) |
| Suggested `BugAction` | `FullSuccessWithDegradation`: emit a FullSuccess record with non-empty `degradation_level` |
| Expected result | classifier invariant violated |
| Owner | TBD |

### RFC-Q2-8: SharedAudit bug model

| Field | Value |
|---|---|
| Spec | `specs/shared/SharedAudit.tla` (119 LOC) |
| Critical safety property | Merkle chain integrity: `prev_hash[i] == hash(entry[i-1])` for `i ≥ 1` |
| Subject of bug action | Tamper detection: any modification to entry[i-1] should break entry[i].prev_hash; runtime surfaces via `Store.verify_chain` |
| Suggested `BugAction` | `TamperEntryInPlace`: re-write `entries[i].id'` (which is the abstracted hash input) without recomputing downstream prev_hash |
| Expected result | `verify_chain` predicate (would need to be invariant) violated |
| Prerequisite | Add `ChainIntegrity` invariant to cfg if not present |
| Owner | TBD |

## 3. Common pattern across stubs

Three of the eight (MASCEcosystem, MultimodalHydrator, SharedAudit) need a **prerequisite** — strengthening the clean cfg's invariant set before adding the BugAction is meaningful. This is the same shape as the OAS chain's Layer C taxonomy: surveys often surface that the tools you'd reach for (a buggy.cfg) need an upstream change first (a stronger clean.cfg invariant).

The other five (AutonomousLoop, AutonomousPhase, MultimodalArtifact, ResilienceDegradation, ResilienceOutcome) have invariants strong enough to catch a realistic bug — only the buggy.cfg + BugAction is missing.

## 4. Effort estimate

For each stub:
- Strong-invariant case (5 specs): ~1h to write buggy `Spec`/`Next` + cfg + verify TLC violates the invariant
- Prerequisite case (3 specs): ~3h — clean invariant addition, manual TLC validation that clean still passes, then the bug-model 1h pass

Total: ~14h spread across 8 small PRs. Each PR is independent (different domain, different file). High parallelism.

## 5. What this Phase deliberately doesn't do

- It doesn't write the buggy cfg or BugAction code. That is the per-RFC follow-up.
- It doesn't pick owners. The fan-out should match domain familiarity per PR.
- It doesn't introduce a `domains_without_bug_model` ratchet floor. The floor of 5 from Phase 1 is the right starting point but should only become enforced after at least 2-3 of these RFCs land — otherwise the ratchet "passes" trivially.

## 6. Phase 4 outline (next)

Phase 4 will wire the descriptive ratchet (`domains_without_bug_model`) per Phase 1 §6, **after** at least 2 of the 8 RFC stubs above have produced merged buggy cfgs. The ratchet starts at the post-merge floor (e.g. 3 if 2 specs merged) so the first enforcement coincides with real progress.

This mirrors the OAS chain's Phase 4 deferral (`bridge_adoption` monotonic floor deferred 6 months pending usage data).

## 7. References

- PR #12123 — Phase 1 (MERGED)
- PR #12132 — Phase 2 (Draft, as of writing)
- `specs/keeper-state-machine/KeeperOASAdvanced.tla` — canonical Bug Model recipe
- CLAUDE.md `TLA+ Bug Model 패턴 (Mutation Testing for Specs)`
- `docs/audit/OAS-MASC-BOUNDARY-AUDIT-2026-04-PHASE3.md` — sister chain Phase 3 (CI wire-up pattern)

*Audit date: 2026-04-30 / Phase 3 of 4 / docs-only / fan-out enumeration*
