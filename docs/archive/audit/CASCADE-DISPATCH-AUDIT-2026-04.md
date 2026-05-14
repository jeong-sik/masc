# Cascade Dispatch Surface Audit — Phase 1

**Date**: 2026-04-30
**Scope**: cascade dispatch decision points in `lib/cascade/`, `lib/keeper/keeper_cascade*`, supporting bridges
**Pattern**: 4-phase audit (`docs/process/AUDIT-CHAIN-4-PHASE-PATTERN.md`, PR #12193)
**Position**: Fourth application of codified pattern (after Dashboard #12202/#12208, Auth #12209/#12217, Server HTTP #12213/#12218).

## 1. Surface

`lib/`-wide cascade-related files: 58 ml + mli. Of those, dispatch-decision-relevant scope: ~20 modules.

### 1.1 Core dispatch modules (decision points)

| Module | Role |
|---|---|
| `lib/cascade/cascade_strategy.{ml,mli}` | Strategy ordering (7 kinds: Failover, Capacity_aware, Weighted_random, Circuit_breaker_cycling, Priority_tier, Sticky, Round_robin) |
| `lib/cascade/cascade_fsm.{ml,mli}` | Accept / Try_next / Exhausted decisions |
| `lib/cascade/cascade_pool_router.{ml,mli}` | Keeper → pool assignment + tier fallback |
| `lib/cascade/cascade_runtime.{ml,mli}` | Model → provider resolution + context binding |
| `lib/cascade/cascade_strategy_trace.{ml,mli}` | Ring buffer for cycle decisions (telemetry anchor) |
| `lib/cascade/cascade_health_tracker.{ml,mli}` | Success rates + cooldown state |
| `lib/cascade/cascade_config_loader.{ml,mli}` | Runtime configuration reload |

### 1.2 Bridges (out-of-scope for dispatch decisions, but relevant context)

- `lib/dashboard/dashboard_cascade*.ml` — UI projection of cascade state
- `lib/oas_worker_cascade*.ml`, `lib/oas_worker_named_cascade.ml` — OAS-side caller
- `lib/server/server_routes_http_routes_cascade.ml` — HTTP exposure (already audited in PR #12218)

## 2. Gap taxonomy (Phase 1 candidates — conservative bias)

| Class | Description | Estimate | Severity |
|---|---|---|---|
| C1 | FSM decision point without strategy trace | 2 (`cascade_fsm.decide`, `cascade_pool_router.execute_with_fallback`) | Medium |
| C2 | Tier fallback without per-tier visibility | 1 (`cascade_pool_router` Tier1 → Tier2 → Emergency loop returns generic `All_pools_exhausted`) | Medium-High |
| C3 | Timeout / retry semantics without property tests | 2 (`cycle_policy` backoff calc, `cooldown_*` invariants) | Medium |
| C4 | Provider failure classification by string instead of variant | 1 candidate (provider key derivation; Result-string errors) | Medium (per memory `feedback_no-string-matching-classification`) |
| C5 | Strategy configuration without TLA+ spec coverage | 1 candidate (Priority_tier `tiers=[...]` nesting + Sticky TTL semantics — `kind` has `[@@deriving tla]` but field-level structure not yet specified) | Low |
| C6 | Anchors (already covered) | 3 (`cascade_strategy_trace.record`, `cascade_health_tracker` counters, `cascade_config_loader` reload tracing) | Low (reference) |

### 2.1 Severity rationale

- **C2 = Medium-High** — bulkhead pattern enumerates fallback tiers but loses per-tier signal in the error. When all pools fail, ops sees `All_pools_exhausted` without knowing whether Tier1 or Tier2 path failed first. Past `feedback_oas_timeout_budget_late_cascade_exhaustion` is a precedent: cascade exhaustion needed line-level tier visibility to triage.
- **C4 = Medium** — string-based provider key resolution fits the recurring AI-generation antipattern from `feedback_no-string-matching-classification`. Errors are validation Result strings rather than algebraic variants.
- **C3 = Medium** — `backoff_base_ms`, `backoff_cap_ms`, `cooldown_sec` all configurable; no QuickCheck or Eio property tests for invariants like `backoff(n) ≤ backoff_cap_ms ∀ n`.
- **C1 = Medium** — `cascade_fsm.decide` is pure (no trace); callers (`oas_worker_named_cascade`) log outcomes at Info level only. C1 is downstream of whether FSM should own its trace ring vs. relying on caller instrumentation.

### 2.2 Conservative-bias predictions for Phase 2 (per pattern doc §4.5)

Likely Phase 2 outcomes:
- **C1** could be **narrow-discover** — if Phase 2 confirms callers don't propagate FSM transitions into `cascade_strategy_trace`, the gap is real and structural (needs FSM-level trace, not caller-level).
- **C5** could be **narrow-collapse** — if Phase 2 finds `Priority_tier tiers` is already covered by an existing TLA spec via the parent `kind` constructor parameters, C5 disappears.
- **C2** could be **narrow-confirm** — explicit per-tier counters are clearly missing; Phase 2 will count them.
- **C6** anchors should be verified against the **anchor-falsification** caveat (PR #12217 precedent): `cascade_health_tracker` counters and `cascade_config_loader` traces should be checked for actual Prometheus emission, not just function names.

## 3. Recommended ratchets (Phase 4 deferred)

```
cascade_dispatch_decision_traces        (INC, floor TBD)
  Purpose: count of dispatch decision points (FSM, pool_router)
  with structured trace emission. Phase 2 enumerates the
  current count.

cascade_tier_fallback_visibility        (INC, floor 0)
  Purpose: count of fallback tiers that emit per-tier success/
  exhaustion counters. Currently 0 (single generic error).

cascade_timeout_retry_property_tests    (INC, floor 0)
  Purpose: count of property test cases verifying cycle_policy
  backoff + cooldown invariants. Currently 0.
```

C4 (provider failure classification) and C5 (TLA spec on `Priority_tier tiers`) are Phase 2 candidates pending narrow-collapse check; ratchets are intentionally not proposed yet.

## 4. Phase 2 plan (next PR)

1. **C1 / FSM trace coverage** — for each `cascade_fsm.decide` and `cascade_pool_router.execute_with_fallback` call site, check whether the *caller* propagates the decision into `cascade_strategy_trace.record`. If yes → C1 collapses. If no → C1 stays as narrow-discover (FSM should own its trace).
2. **C2 / tier fallback** — enumerate `Tier1 / Tier2 / Emergency` constants in `cascade_pool_router.ml`, count counters per tier (expected: 0).
3. **C3 / property tests** — search `test/` for `Cascade_strategy.cycle_policy` or `cooldown` property test setup; expected: none.
4. **C4 / provider error variant** — read `cascade_runtime.ml` provider key resolution and confirm whether errors are `(_, string) result` or an algebraic variant.
5. **C5 / TLA spec coverage on `tiers`** — check `specs/boundary/CascadeStrategy.tla` and `CascadeStrategyStateful.tla` for explicit modeling of Priority_tier tier nesting + Sticky TTL.
6. **C6 anchor verification** — Prometheus grep on `cascade_health_tracker.ml` and `cascade_config_loader.ml`. Mark each as confirmed-anchor or anchor-falsified.

## 5. Out-of-scope for Phase 1

- Cascade UI (dashboard_cascade*) — already covered by Dashboard observability audit (#12202/#12208)
- Cascade HTTP route — already covered by Server HTTP routes audit (#12213/#12218)
- OAS-side caller `oas_worker_named_cascade.ml` — touches OAS↔MASC boundary; covered there

## 6. Audit chain context

| # | Chain | Codified-pattern invocation |
|---|---|---|
| 1 | OAS↔MASC boundary | source |
| 2 | TLA+ specs gap | second instance |
| 3 | TLA+ PPX adoption | third instance |
| 4 | Dashboard observability | first to invoke codified pattern |
| 5 | Auth/credential | second |
| 6 | Server HTTP routes | third |
| 7 | **Cascade dispatch (this PR)** | fourth |

This audit is the **first runtime-decision-logic chain** under the codified pattern. Prior new-domain chains (dashboard, auth, server HTTP) covered observability/security/transport. Cascade dispatch is closer to OAS↔MASC boundary in shape (decision invariants + provider-side side effects) but sits inside the masc-mcp library, not at the OAS boundary.

## 7. References

- PR #12193 — 4-phase pattern (codification)
- PR #12202 / #12208 — Dashboard observability (sibling chain)
- PR #12209 / #12217 — Auth/credential (sibling chain)
- PR #12213 / #12218 — Server HTTP routes (sibling chain)
- `lib/cascade/cascade_strategy.{ml,mli}`, `cascade_fsm.{ml,mli}`, `cascade_pool_router.{ml,mli}` — primary surface
- `specs/boundary/CascadeStrategy.tla`, `CascadeStrategyStateful.tla` — existing TLA coverage (kind variant)
- `MEMORY.md`: `feedback_oas_timeout_budget_late_cascade_exhaustion` (C2 precedent), `feedback_no-string-matching-classification` (C4 precedent)

## 8. Summary table

| Metric | Value |
|---|---|
| Total cascade-related ml/mli files | 58 |
| Dispatch-decision modules in scope | ~20 (7 core + supporting) |
| C1+C2+C3 candidates | 5 |
| C4+C5 conservative candidates | 2 |
| C6 anchors | 3 (pending Phase 2 verification) |
| Recommended ratchets | 3 |
