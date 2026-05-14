# KCAF D-1 Audit — Attempt FSM topology + coverage gaps

**Iteration**: 30 (/loop FSM/TLA+/OCaml drift hunt — first KCAF entry)
**Date**: 2026-05-12
**Spec**: `specs/keeper-state-machine/KeeperCascadeAttemptFSM.tla` (263 LOC, RFC-0065 Phase 5.1 B1)
**OCaml**: `lib/cascade/cascade_fsm.ml:7-21` (typed surface), `lib/keeper/keeper_turn_driver.ml::try_cascade` (recursive walker), `lib/keeper/keeper_turn_slot.ml::with_keeper_turn_slot` (slot guard)
**Risk**: MID — spec models 3 sub-classes of `Call_err` (cascadeable / terminal / hard_quota) that the OCaml side collapses into ONE `Call_err` constructor + runtime classifier.  The classification gap is invisible to the R-B-1.c drift validator.
**Type**: Audit-only (first entry for Phase D — KCAF was previously unreviewed in this /loop).

## Spec topology

| | Members | Source |
|---|---|---|
| `attempt_phase` PhaseSet | 6: `idle`, `attempting`, `awaiting_response`, `success`, `exhausted_normal`, `exhausted_hard_quota` | line 79-81 |
| TerminalSet | 3: `success`, `exhausted_normal`, `exhausted_hard_quota` | line 83-84 |
| ProviderOutcomes (CONSTANT) | 6: `call_ok`, `call_err_cascadeable`, `call_err_terminal`, `call_err_hard_quota`, `accept_rejected`, `slot_full` | cfg-supplied |
| Actions (Next) | 6: `StartCascade`, `SendRequest`, `ResolveSuccess`, `ResolveTryNext`, `ResolveExhaustedNormal`, `ResolveHardQuota` | line 108-182 |
| BugActions (NextBuggy) | 3: `BugHardQuotaBypass`, `BugSemaphoreRelease`, `BugTryNextLoops` | line 191-220 |
| Invariants | 3 (+ TypeOK): `SlotReleasedOnTerminal`, `HardQuotaTerminalImmediate`, `TryNextProgresses` | line 234-261 |

This is the *most sophisticated* spec in the FSM family so far — explicit Bug Model, 3 BugActions, structurally proof-friendly.  No `KNOWN_FAILURES` listing.

## OCaml topology

```ocaml
(* lib/cascade/cascade_fsm.ml:7-13 *)
type provider_outcome =
  | Call_ok of Llm_provider.Types.api_response     [@tla.symbol "call_ok"]
  | Call_err of Llm_provider.Http_client.http_error [@tla.symbol "call_err"]
  | Accept_rejected of {...}                        [@tla.symbol "accept_rejected"]
  | Slot_full                                        [@tla.symbol "slot_full"]
[@@deriving tla]

(* lib/cascade/cascade_fsm.ml:15-20 *)
type decision =
  | Accept of ...           [@tla.symbol "accept"]
  | Accept_on_exhaustion of {...} [@tla.symbol "accept_on_exhaustion"]
  | Try_next of {...}       [@tla.symbol "try_next"]
  | Exhausted of {...}      [@tla.symbol "exhausted"]
(* note: no [@@deriving tla] derive *)
```

Phase machine is *implicit* — `attempt_phase` lives only in `try_cascade` recursion structure, not as a typed variable.  The spec is *more explicit* than OCaml on the FSM topology.

## Three concrete gap classes

### Gap 1 — `Call_err` runtime-classified (spec 3-way, OCaml 1-way + filter)

Spec distinguishes 3 error categories at the ALPHABET level:
- `call_err_cascadeable` → drives `ResolveTryNext` (when not last tier)
- `call_err_terminal` → can drive `ResolveExhaustedNormal` (when last tier)
- `call_err_hard_quota` → drives `ResolveHardQuota` (overrides decide, no tier advance)

OCaml has ONE `Call_err` constructor.  The classification happens *inside* `decide`:

```ocaml
(* lib/cascade/cascade_fsm.ml:47-52 *)
| Call_err err ->
  let should_cascade = Cascade_health_filter.should_cascade_to_next err in
  if should_cascade then Try_next { last_err = Some err }
  else Exhausted { last_err = Some err }
```

And the hard-quota branch lives in `keeper_turn_driver.ml:657-669` (separate file, separate code path).  Three distinct sub-semantics are reconstructed from runtime predicates rather than statically distinguished at the type level.

**Consequence**: Bug `BugHardQuotaBypass` (spec line 191) maps to "OCaml accidentally removes the hard_quota override branch in keeper_turn_driver.ml".  But the change site is *outside* `cascade_fsm.ml` — a code review reading only `cascade_fsm.ml` cannot detect the bug.  Spec captures the cross-file coupling that OCaml doesn't.

### Gap 2 — `decision` lacks `[@@deriving tla]`

```ocaml
type decision = | Accept | Accept_on_exhaustion | Try_next | Exhausted
(* — no [@@deriving tla] *)
```

The decision-side variants have `[@tla.symbol ...]` annotations on each constructor, but no `[@@deriving tla]` on the type.  The R-B-1.c drift validator (iter 20, #14770) only scans types carrying `[@@deriving tla]`, so this drift class is invisible.

Practical impact: today the four `decision` variants happen to match the four spec resolution actions (`ResolveSuccess`, `ResolveExhaustedNormal`, `ResolveHardQuota`, plus `Try_next` driving `ResolveTryNext`).  But if a future OCaml change adds a 5th decision (e.g. `Reroute_provider`) without spec sync, validator silence persists.

### Gap 3 — Validator coverage missing for KCAF

`scripts/audit-tla-annotation-drift.sh` (iter 20) `TYPE_SET_PAIRS` array (line 79-87):

```bash
declare -a TYPE_SET_PAIRS=(
  "turn_phase:TurnPhaseSet"
  "decision_stage:DecisionSet"
  "cascade_state:CascadeSet"
)
```

KCAF's `provider_outcome ↔ ProviderOutcomes` mapping isn't here.  Two structural reasons:

1. `ProviderOutcomes` is a CONSTANT (cfg-supplied), not a closed set literal in the spec.  The current `extract_set_members` awk pass greps for `XxxSet == { ... }` blocks; CONSTANTs are sourced from `.cfg` files.
2. `attempt_phase` has no OCaml type to compare against (implicit FSM), so the validator has no symbol set to check.

**Validator gap**: even if Gap 1's `Call_err` 3-way split landed in OCaml, the current validator wouldn't catch a future regression that collapsed it back, because it doesn't know about `provider_outcome`.

## Three RFC candidates

| ID | Direction | Risk |
|---|---|---|
| R-D-1.a | OCaml — split `Call_err` into typed sub-variants: `Call_err_cascadeable of http_error`, `Call_err_terminal of http_error`, `Call_err_hard_quota of http_error`.  Push classification (`should_cascade_to_next`, `sdk_error_is_hard_quota`) from runtime predicates to constructor selection.  Spec's 3-way alphabet becomes OCaml's 3-way variant. | MID — touches `cascade_fsm.ml` + `keeper_turn_driver.ml` + every `Call_err _` pattern match in callers. |
| R-D-1.b | Validator — extend `TYPE_SET_PAIRS` to support CONSTANT-style sets by reading TLC cfg files (`grep -E "^[A-Z][a-zA-Z]+ *= *\{" specs/keeper-state-machine/*.cfg`).  Add `provider_outcome:ProviderOutcomes` (cfg-sourced).  Add `decision:DecisionSet` once `[@@deriving tla]` lands on `decision`. | LOW-MID — script change, ~30 LOC + paired baseline update. |
| R-D-1.c | OCaml — add `[@@deriving tla]` to `decision` type.  No semantic change; type becomes scannable by R-B-1.c validator.  Pairs with R-D-1.b adding `decision:DecisionSet` to the pair list. | LOW — single annotation line + paired validator update. |

R-D-1.c is the cheapest *visibility* fix.  R-D-1.a is the structurally cleanest *correctness* fix (matches spec alphabet at type level).  R-D-1.b is the *infrastructure* fix needed for either to be enforced going forward.

## Why production stays correct (today)

- `Cascade_health_filter.should_cascade_to_next` and `sdk_error_is_hard_quota` are well-tested predicates with corpus coverage on real provider responses.  Reclassification regressions would surface in those test suites before reaching the FSM-level invariants.
- The 3-BugAction model in KCAF's `-buggy.cfg` *does* catch the canonical regressions (hard-quota bypass, mid-cascade slot release, off-by-one tier walker).  Coverage of those bugs is verified at TLC level on every spec-touching PR.
- Slot-leak (`SlotReleasedOnTerminal`) is enforced *by construction* via `Fun.protect` in `with_keeper_turn_slot` — independent of FSM correctness.

So this is a *coverage breadth* finding, not a runtime bug.  Production correctness rests on integration tests + the Fun.protect finalizer + the BugAction model; static type symmetry between spec and OCaml is the *additional* line of defense that doesn't yet exist.

## Comparison with prior audits

| Audit | Spec representation | OCaml representation | Drift class |
|---|---|---|---|
| KSM A-1 (#14694) | 18 conditions + closed phase set | derive_phase priority chain | Init mapping under-models |
| KTC B-1 (#14767) | 5-member TurnPhaseSet | 7-constructor turn_phase | OCaml ahead — closed iter 28 #14793 |
| KCR C-1 (#14776) | `fallback_count` Nat + cap | visited-list cycle detection | Different cap mechanism |
| KCR C-2 (#14777) | typed 3-state health | 2-state typed + implicit int | Representation mismatch |
| KCT C-3 (#14783) | `"none"` literal for terminal | `base_cascade` return | OCaml more permissive |
| KCT S2/S3 (#14787) | string-literal cascade names | catalog-resolved names | OCaml more configurable |
| **KCAF D-1 (this)** | 3-way alphabet + closed FSM | 1-way constructor + runtime classifier + implicit FSM | **Runtime classification at type boundary** |

KCAF is the first audit where the drift is *runtime predicate vs static type alphabet* — a new shape.  R-D-1.a's split would convert that runtime classification into a type-level distinction, the same pattern as Alexis King's "parse, don't validate" (CLAUDE.md §Coding Principle).

## Out-of-scope for this iteration

- D-2 (`exhausted_normal` vs `exhausted_hard_quota` semantics) — separate audit slice.
- R-D-1.a/b/c implementation — separate PRs (any of the three is a 1-iteration target).
- KCAF-buggy TLC re-verify — already passing on current main (no spec change in this PR).
- Validator extension to KSM `phase` (mentioned in validator source comment line 83-86) — different scope.

## References

- KCAF spec §1-263 (full file).
- `lib/cascade/cascade_fsm.ml:7-21` (typed surface).
- `lib/cascade/cascade_fsm.ml:25-52` (`decide` function — runtime classification site).
- `lib/keeper/keeper_turn_driver.ml:657-669` (hard-quota override).
- `scripts/audit-tla-annotation-drift.sh:79-87` (`TYPE_SET_PAIRS` extension point).
- KSM A-1 audit (`ksm-init-mapping-2026-05-12.md`) — same shape "spec stricter typing, OCaml runtime decision".
- KCR C-2 audit (`kcr-c2-health-state-representation-gap-2026-05-12.md`) — sibling drift class (representation mismatch).
- RFC-0065 Phase 5.1 B1 — KCAF spec authoring origin.
