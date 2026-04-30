# Cascade Dispatch Surface Audit — Phase 2 (verdict refinement)

**Date**: 2026-04-30
**Scope**: same as Phase 1 — 7 core dispatch decision modules
**Pattern**: 4-phase audit (`docs/process/AUDIT-CHAIN-4-PHASE-PATTERN.md`, PR #12193 / §4.5 added in PR #12223)
**Phase 1**: PR #12222

## 1. Phase 1 prediction vs Phase 2 actual

Phase 1 (PR #12222) made explicit predictions per the §4.5 outcome categories. Phase 2 verifies each.

| Class | Prediction | Actual outcome | Match |
|---|---|---|---|
| C1 FSM/router decision w/o trace | narrow-discover | narrow-discover (FSM is pure; callers may not propagate) | ✅ |
| C2 tier fallback w/o per-tier visibility | narrow-confirm | narrow-confirm (Tier1/Tier2/Emergency defined, 0 per-tier counters) | ✅ |
| C3 timeout/retry property tests | TBD | narrow-collapse (no cascade-specific PBT exists; gap not as deep as feared) | — |
| C4 provider failure classification by string | TBD | **falsified** — already 6-variant algebraic ADT (`Llm_provider.Http_client.http_error`) | ❌ |
| C5 Priority_tier tiers/TTL TLA+ coverage | narrow-collapse | narrow-collapse confirmed (`CascadeStrategyStateful.tla` says "Priority_tier is stateless") | ✅ |
| C6 anchors | anchor-falsification check | **partial falsification** — `cascade_strategy_trace` real anchor, `cascade_health_tracker` and `cascade_config_loader` false anchors | partial |

**Predictions correct: 3/4 explicit + partial C6. Falsifications: 1 (C4).**

This is the first audit chain where a Phase 1 candidate is fully falsified before Phase 2 even started narrowing. C4 was a *Phase 1 candidate, not a confirmed gap* — but the §4.5 framework didn't yet have a name for "Phase 1 invents a gap that doesn't exist." Phase 2 surfaces this as a fifth outcome category worth folding back into the pattern doc: **gap-invented** (Phase 1 hypothesizes a gap based on a recurring antipattern that turns out not to apply to this domain).

## 2. Per-class structural findings

### 2.1 C1 — narrow-discover confirmed

`cascade_fsm.decide` and `cascade_pool_router.execute_with_fallback` are pure (no `Cascade_strategy_trace.record` call). The actual trace recording lives at the call site (e.g., `oas_worker_named.ml`). Phase 3 work for C1 must answer: should FSM/router own its trace ring, or do we mandate caller-side propagation? The latter risks silent drift if a new caller is added without trace wiring; the former couples FSM/router to the trace module.

Recommendation: caller-side propagation **plus** a structural test that asserts every `cascade_fsm.decide` call site is followed by a trace record within the same call chain. This is a property-test target.

### 2.2 C2 — narrow-confirm confirmed

`cascade_pool_router.ml` defines `Tier1`, `Tier2`, `Emergency` tier constants (lines 8/11/14). Zero `inc_counter` or `metric_*` calls in the module. `Cascade_pool` maintains `health_tracker` per pool but no per-tier metrics.

Phase 3 work: introduce three counters (`cascade_tier_dispatched_total{tier="..."}`, `cascade_tier_exhausted_total{tier="..."}`, `cascade_tier_fallback_promoted_total{tier="..."}`).

### 2.3 C3 — narrow-collapse

No cascade-specific property tests exist in `test/`. 8 `*_pbt.ml` files exist for other domains; none cover cascade `cycle_policy` backoff or cooldown invariants. Cooldown is tested in `test_keeper_unified.ml` as unit assertions (cooldown_sec blocking) — not property style.

Gap is real but smaller than feared (Phase 1 estimated 2 specific test classes; Phase 2 finds the gap is "no PBT framework engagement at all for cascade").

### 2.4 C4 — falsified (gap-invented)

`Llm_provider.Http_client.http_error` is a 6-variant ADT:

```
HttpError { code; body }
AcceptRejected { reason }
CliTransportRequired { kind }
NetworkError { message; kind }
ProviderTerminal _
ProviderFailure _
```

Pattern matching at decision points (`cascade_fsm.ml` lines 54, 60–66) classifies via variants, not strings. Phase 1 hypothesized this gap based on the recurring `feedback_no-string-matching-classification` antipattern but did not actually verify. The hypothesis was wrong for this domain.

Lesson: even with conservative-bias rules, Phase 1 should run the *cheapest possible* structural check before naming a candidate. A 30-second `rg 'type http_error'` would have prevented the C4 candidate. **gap-invented** is the new outcome category for this case.

### 2.5 C5 — narrow-collapse confirmed

`CascadeStrategyStateful.tla` line 18 explicitly states "Priority_tier is stateless; no variables here." `Sticky` and `Round_robin` maintain side tables; Priority_tier nesting is a runtime data shape but TLA-irrelevant by design. The existing `kind` variant `[@@deriving tla]` covers the routing decision space.

C5 ratchet drops entirely — there is no spec gap to fill.

### 2.6 C6 — partial anchor-falsification

| File | Prometheus calls | Anchor status |
|---|---|---|
| `lib/cascade/cascade_strategy_trace.ml` | 2 (line 59 `inc_counter`, line 60 `metric_cascade_strategy_decisions`) | **real anchor** |
| `lib/cascade/cascade_health_tracker.ml` | 0 | **false anchor** |
| `lib/cascade/cascade_config_loader.ml` | 0 | **false anchor** |

Phase 1 listed all 3 as anchors based on functional naming. Only `cascade_strategy_trace` qualifies. Same anchor-falsification pattern as Auth Phase 2 (PR #12217) — Phase 1 over-counted *coverage*, not gaps.

## 3. Refined ratchet floors

```
cascade_dispatch_decision_traces       (INC, floor 1)
  Current: 1 (cascade_strategy_trace itself).
  Goal: every FSM/router decision propagates via record.

cascade_tier_fallback_visibility       (INC, floor 0)
  Current: 0. Phase 3 adds 3 per-tier counters.

cascade_health_tracker_telemetry       (INC, floor 0)  [NEW]
  Current: 0 calls. Phase 3 adds counter for cooldown
  enter/exit transitions.

cascade_config_loader_telemetry        (INC, floor 0)  [NEW]
  Current: 0 calls. Phase 3 adds counter for reload
  success/failure.

cascade_timeout_retry_property_tests   (INC, floor 0)
  Current: 0. Phase 3 adds at least 1 PBT covering
  backoff(n) ≤ backoff_cap_ms invariant.
```

C4 (provider classification) and C5 (Priority_tier TLA) ratchets dropped — gap doesn't exist.

## 4. Pattern doc feedback (proposed §4.5 amendment)

This Phase 2 produces a **new fifth outcome category** worth folding back:

**gap-invented**: Phase 1 names a gap class based on a recurring repo-wide antipattern, but the domain in question doesn't actually exhibit it. Distinct from narrow-collapse (where the gap was real but turned out smaller) — gap-invented means the Phase 1 candidate was wrong from inception.

Mitigation: even Phase 1 should run a 30-second cheapest-possible structural check before naming candidates from generic antipattern memory.

## 5. Phase 3 priorities

Tier P1 (high signal, low risk):
- Property test on cascade_strategy backoff/cooldown invariants (1 PBT)
- Per-tier counters in cascade_pool_router (3 counters, one PR)
- cascade_health_tracker counter on cooldown transitions (1 counter)

Tier P2 (caller-discipline):
- Structural test: every `cascade_fsm.decide` call site is followed by `Cascade_strategy_trace.record` in the same chain

Tier P3 (drop):
- C4 provider-error variant migration (already done)
- C5 Priority_tier TLA spec extension (out of scope)

## 6. Audit chain context

Seventh chain Phase 2; fourth under codified pattern. First chain to produce gap-invented outcome — strengthens the pattern doc with a fifth outcome category.

## 7. References

- PR #12222 — Phase 1 (parent)
- PR #12193 / #12223 — pattern doc + §4.5
- PR #12217 — Auth Phase 2 (anchor-falsification precedent)
- `lib/cascade/cascade_fsm.ml`, `cascade_pool_router.ml` — primary surface
- `specs/boundary/CascadeStrategyStateful.tla` — C5 evidence
- `lib/llm_provider/http_client.ml` — C4 evidence (6-variant ADT)
