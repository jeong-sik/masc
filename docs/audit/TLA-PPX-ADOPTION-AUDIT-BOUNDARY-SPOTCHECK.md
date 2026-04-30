# TLA+ PPX Adoption Audit — boundary domain spot-check

> Status: Targeted spot-check of 3 boundary specs.
> Author: Vincent (jeong-sik) with Claude
> Created: 2026-04-30
> Tracks: PR #12143 §9.1 follow-up
> Companion: `docs/audit/TLA-PPX-ADOPTION-AUDIT-2026-04.md`

---

## 1. Scope

The Cycle 14 PPX adoption audit (#12143) flagged the boundary domain (25 specs, 0 PPX hooks) as the largest unhooked surface and proposed a spot-check to determine whether boundary specs even have OCaml ADTs to derive (some model cross-domain protocols without a single owner).

This document checks 3 representative boundary specs.

## 2. Method

For each spec:
1. Read the spec header for the runtime mapping (often in the comment block at top).
2. Locate the OCaml module(s) the spec claims to mirror.
3. Check whether the OCaml side exposes a single variant `type` that mirrors a TLA `StateSet`-style literal set.
4. Classify: **mappable** (single ADT owner, `[@@deriving tla]` candidate) vs **cross-domain** (multi-owner protocol, no single type).

## 3. Findings

### 3.1 `boundary/CascadeStrategy.tla` — **mappable**

Spec mirrors `lib/cascade/cascade_strategy.{ml,mli}` (Phase A #7606 + Phase B #7611).

```ocaml
(* lib/cascade/cascade_strategy.mli:127 *)
type kind =
  | Failover
  | Capacity_aware
  | Weighted_random
  | Circuit_breaker_cycling
  | Priority_tier
  | Sticky
  | Round_robin
  ...
```

8-variant nullary ADT — perfect `[@@deriving tla]` shape. The TLA spec models the strategy choice non-deterministically; the OCaml `kind` is the SSOT. Adding `[@@deriving tla]` gives `to_tla_symbol`, `all_symbols`, drift-free.

**Verdict**: candidate for follow-up code PR (similar to the resilience adoption PR — `[@@deriving tla]` + dune preprocessor). Estimated cost: 1 cycle.

### 3.2 `boundary/CascadeKeeperRecovery.tla` — **cross-domain**

Per spec header:

> Domain boundary:
>   - OAS/provider health availability
>   - keeper_unified_turn retry loop
>   - KeeperStateMachine / keepalive crash escalation
>   - supervisor restart path

The spec models the **interaction** of 4 separate runtime owners. There is no single OCaml `type t = | A | B | ...` to derive from — the spec is a cross-domain assertion about how Cascade availability, keeper turn retry, keepalive, and supervisor compose.

**Verdict**: not a `[@@deriving tla]` candidate. The mapping comment in the spec header lists 4 modules. Runtime instrumentation here would be `[@@fsm_guard]` on the *boundary actions* (e.g. `assert (provider_healthy => keeper_state /= Failing)`), not symbol-table generation.

### 3.3 `boundary/KeeperContractViolated.tla` — **cross-domain**

Models the keeper completion-contract gate (`require_tool_use`). Runtime contract spans:
- `lib/keeper/keeper_run_tools.mli` (contract surface)
- `lib/keeper/keeper_turn_terminal.ml` (gate decision)
- `lib/keeper/keeper_tool_disclosure.mli` (LLM-visible affordances)

The spec encodes a **production-derived bug** (43 events / 24h fleet log, see `feedback_proactive_turn_contract_violation_dominant`). The bug is "gate detects violation but next turn re-enters with same affordances" — a multi-step contract, not a state-set.

**Verdict**: not a `[@@deriving tla]` candidate. Runtime instrumentation here would be `[@@fsm_guard "violations_signaled_to_llm = true"]` on the post-detection turn handoff, NOT symbol generation.

## 4. Pattern (Phase 1-style classification)

| Class | Count in 3-spec sample | Generalisation hypothesis |
|---|---|---|
| **mappable** (single ADT owner) | 1 (CascadeStrategy) | ~⅓ of boundary specs likely follow this pattern when the spec is named after a single module |
| **cross-domain** (multi-owner protocol) | 2 (CascadeKeeperRecovery, KeeperContractViolated) | ~⅔ of boundary specs mirror runtime *interactions*, not types |

Generalising from N=3 is statistically thin, but the 1:2 split aligns with how boundary specs are framed in their headers (interaction language vs ADT language). A full sweep of 25 boundary specs would refine the ratio.

## 5. Implication for Cycle 14 §9 step 1

The §9.1 step "boundary domain spot-check" intended to inform whether mass `[@@deriving tla]` adoption to boundary makes sense. Answer: **partially**.

- **Mappable subset**: viable as one PR per ADT (CascadeStrategy is the first candidate, queued as a follow-up).
- **Cross-domain subset**: needs `[@@fsm_guard]` instead, applied at the *interaction action* level. This requires reading each spec's `Next` predicate to identify which boundary action carries the invariant.

The `[@@deriving tla]` ratchet floor (Cycle 14 §8) should not assume linear domain → adoption. boundary domain may peak at ~⅓ derivation coverage and the remaining ⅔ shifts to `[@@fsm_guard]` adoption.

## 6. Recommendation

Do NOT promote `domains_with_zero_ppx_link` to a hard ratchet that treats boundary's 25-spec count as one bucket. Instead:
- Subdivide: `boundary_mappable_specs_with_deriving_tla` (target: monotonic increase)
- `boundary_crossdomain_specs_with_fsm_guard` (target: monotonic increase)

Or simpler: keep the existing 3-metric proposal from Cycle 14 §8 and accept that boundary domain scores partial coverage on `ppx_deriving_tla_modules` indefinitely.

## 7. Suggested next steps (out of scope)

1. **CascadeStrategy `[@@deriving tla]` adoption PR** (1 cycle, similar to resilience PR pattern).
2. **Full 25-spec boundary sweep**: classify each as mappable/cross-domain. Mechanical (read header + grep for ADT). ~2h.
3. **`[@@fsm_guard]` extension to cross-domain boundary actions**: per-spec analysis required. Higher effort, higher leverage.

## 8. References

- PR #12143 — Cycle 14 PPX adoption audit (parent)
- PR #12132 §6 — sister chain Phase 2's surfacing-of-naming-drift, same survey pattern
- `lib/cascade/cascade_strategy.{ml,mli}` — CascadeStrategy ADT
- `specs/boundary/CascadeStrategy.tla`, `specs/boundary/CascadeKeeperRecovery.tla`, `specs/boundary/KeeperContractViolated.tla`
- Memory: `feedback_proactive_turn_contract_violation_dominant` (production-derived spec)

*Audit date: 2026-04-30 / spot-check 3-of-25 / docs-only*
