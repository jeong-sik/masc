# KOAS M-1 — KeeperOASAdvanced spec vs OCaml runtime (audit)

**Iteration**: /loop iter 61 — first entry to Phase M (`KeeperOASAdvanced.tla`).
**Date**: 2026-05-12.
**Scope**: audit-only. No spec or OCaml mutation in this PR.

## Discovery

KOAS models the OAS Bridge timeout/error boundary with eight state variables, eleven actions, and a *paired and verified* bug model fixture.  It is the strongest spec discipline encountered in the loop so far (`Bug Model` invariant pattern from `instructions/software-development.md`).  But the spec's distinctive runtime concepts — `external_side_effect_committed`, `continue_gate_required`, `context_polluted` — appear *zero times* anywhere in the codebase.

| Spec concept | OCaml runtime location | Coverage |
|--------------|------------------------|----------|
| `sys_stop_requested` / `fiber_state` | Eio.Switch + Eio.Cancel.Cancelled idioms scattered | Indirect; no single owner |
| `oas_api_state` (Idle/Fetching/Success/Error) | `lib/oas_compat/` (compat shim) + ad-hoc call sites | Partial |
| `cascade_turn` | cascade modules (lib/cascade/) | Partial |
| `keeper_decision` (Unknown/ExecuteSelf/AutonomyFallback/Delegate/NeedsContinueGate) | none | Missing |
| `context_polluted` | none | Missing |
| `external_side_effect_committed` | none | Missing |
| `continue_gate_required` | none | Missing |

Cross-checked: `rg` across all `lib/` returns zero matches for any of the four "Missing" concepts.

Two OCaml modules touch the OAS surface:

| Module | LOC | Role |
|--------|-----|------|
| `lib/oas_compat/oas_compat.ml` | (small) | Compatibility shim over OAS protocol |
| `lib/keeper/oas_execution_error_phase.ml` | (~30) | Closed sum of 7 phases used as Prometheus label on `metric_keeper_oas_execution_errors` |
| `lib/keeper/keeper_oas_checkpoint.ml` | (small) | OAS checkpoint snapshot handling |

None of them model the spec's `external_side_effect_committed` / `continue_gate_required` distinction — the spec's most operationally important contribution (it differentiates clean Eio cancellation rollback from cases where an outside-world mutation has already committed and needs an explicit operator decision).

## New first-entry sub-class: paired bug-model verified, but design-ground

iter 58 KRL was *design-ground without runtime*.  KOAS is the same gap shape, but distinguished by spec-side maturity:

| Aspect | iter 58 KRL (L-1) | iter 61 KOAS (M-1) |
|--------|-------------------|--------------------|
| Spec LOC | 327 | 252 |
| Runtime LOC matching | 91 (event queue) + 3037 (unified turn), 0 spec-concept hits | ~30 (error_phase enum) + small compat/checkpoint, 0 spec-concept hits |
| Bug-Model fixture | one buggy cfg, no verified counter-example documented | **paired and verified**: `KeeperOASAdvanced-buggy.cfg` with `CancelledNeverAbsorbed` invariant; memory `reference_masc_mcp_integrated_improvement_design_audit.md` records "Clean 56 states/no error. Buggy: invariant violated in 3 steps" |
| Spec discipline | leads-to properties only | bug-model + safety + liveness all paired |
| Implementation tracking | MASC task-134 (explicit) | none cited |

**This is the first first-entry where the spec is *production-ready* (verified bug-model) but the runtime simply doesn't track it.**  Implementation is owed *to* the spec, not the other way around.

## Concrete operational risk

The spec encodes a specific invariant the runtime must satisfy: if an external tool committed a mutation *before* an Eio cancellation, the bridge cannot "claim clean recovery" — it must surface `NeedsContinueGate` for explicit operator continuation.

| Failure path | Spec response | OCaml today |
|--------------|---------------|-------------|
| Cancellation, no external commit | `FiberHandlesCancellation` → AutonomyFallback | (assumed; no explicit code path) |
| Cancellation, external commit done | `CancellationAfterCommittedSideEffect` → NeedsContinueGate | **no path** — runtime cannot distinguish |
| OAS API error, no external commit | `HandleError` → AutonomyFallback | (assumed) |
| OAS API error, external commit done | `HandleErrorAfterCommittedSideEffect` → NeedsContinueGate | **no path** — runtime cannot distinguish |

The two "no path" rows are where the spec's most important distinction lives.  Today's runtime falls back identically in both cases.  In practice this means a tool-side mutation that committed before a fiber cancel/error is *silently absorbed* — there is no continue-gate to make it operator-visible.

## Bug model: `CancelledAbsorbed` matters

The spec's bug model is not theoretical — it models the exact catch-all anti-pattern noted in memory `feedback` and `instructions/software-development.md` (FSM Sparse Match / `_ -> false` catch-all).  An OCaml try/with that catches `Eio.Cancel.Cancelled` and returns a normal `Error _` (instead of re-raising) reproduces `CancelledAbsorbed`: the parent switch never sees the cancel and the keeper appears to "complete normally" while the cancellation signal was eaten.

`CancelledNeverAbsorbed` invariant catches this in 3 TLC steps with the buggy fixture.  Without an OCaml-side equivalent assertion or lint, a careless try/with addition to the bridge code path reintroduces the bug class silently.

## M-2 follow-up candidates

These are call-outs, **not fixes in this audit**.

| Tag | Risk | Description |
|-----|------|-------------|
| **M-2.a** | LOW doc | iter 57 K-2.d / iter 59 L-2.a shape — KOAS preamble Runtime status block stating "spec is production-ready but runtime is missing the `external_side_effect_committed` / `continue_gate_required` distinction".  12th honest-doc datapoint candidate. |
| **M-2.b** | MED runtime | introduce `Oas_bridge.external_commit_witness` type and threading: a token a tool emits when it has committed an outside-world mutation, carried through the cancellation/error handlers so the bridge can choose between AutonomyFallback and NeedsContinueGate.  Maps spec actions 6b/8b to OCaml.  Needs RFC. |
| **M-2.c** | MED runtime | linter / test fixture mirroring `CancelledNeverAbsorbed`: a unit test that wraps a fake bridge with try/with-Cancelled→Error, asserts the parent switch sees Cancelled propagation.  Closes the bug-model loop on the OCaml side. |
| **M-2.d** | LOW TLC refresh | re-run `KeeperOASAdvanced.cfg` and `-buggy.cfg` inside the loop to confirm the "56 states / no error, buggy violates in 3 steps" numbers cited in memory still hold (memory snapshot is 2026-05-05). |

## Pattern catalog update

iter 56 audit catalogued 6 first-entry sub-classes; iter 61 adds a 7th distinction:

| iter | Spec | Sub-class |
|------|------|-----------|
| 1 | KSM A-1 | coverage gap |
| 22 | KCR C-1 | spec drift |
| 38 | KCL E-1 | cross-spec staleness |
| 47 | KCtxL H-1 | doc-layer drift |
| 56 | KAL K-1 | dormancy (flag-gated) |
| 58 | KRL L-1 | design-ground (no runtime) |
| **61** | **KOAS M-1** | **design-ground + verified bug model (runtime owes spec)** |

KOAS is *the same shape* as KRL on the runtime axis (no matching code) but *the opposite shape* on the spec maturity axis (bug-model paired and verified, vs KRL's incomplete liveness fixture).  This means the priority of fixing the runtime gap is different: KRL waits on MASC task-134's design RFC; KOAS waits on someone deciding the bridge's contract is worth enforcing in OCaml.

## Verification (this audit)

| Check | Result |
|-------|--------|
| `wc -l specs/keeper-state-machine/KeeperOASAdvanced.tla` | 252 LOC |
| `ls specs/keeper-state-machine/KeeperOASAdvanced*.cfg` | clean + buggy (paired) |
| `rg -l 'external_side_effect_committed\|continue_gate_required\|context_polluted' lib/` | 0 matches |
| `find lib/ -name 'oas_*' -o -name 'keeper_oas_*'` | `oas_compat/`, `oas_execution_error_phase.ml`, `keeper_oas_checkpoint.ml` |

No spec, OCaml, or .cfg mutation by this PR.  +95 LOC docs/.

## RFC trail

RFC-WAIVED — audit-only memo.  Recommended follow-up RFCs:
- M-2.a (preamble Runtime status note, doc-only, 12th honest-doc datapoint after iter 60 K-2.c lands)
- M-2.b (runtime: `external_commit_witness` type + threading — needs RFC and user direction)
- M-2.c (test fixture: OCaml-side `CancelledNeverAbsorbed` assertion)
- M-2.d (TLC verify refresh — clean + buggy fixtures)

Picked up by iter 62+ when OAS bridge becomes active scope, or as opportunistic finds in the FSM queue.
