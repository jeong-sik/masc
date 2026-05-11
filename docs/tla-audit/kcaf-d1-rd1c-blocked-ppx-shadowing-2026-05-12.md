# KCAF R-D-1.c Correction — ppx_tla shadowing blocks single-annotation fix

**Iteration**: 31 (/loop FSM/TLA+/OCaml drift hunt)
**Date**: 2026-05-12
**Spec**: `specs/keeper-state-machine/KeeperCascadeAttemptFSM.tla`
**OCaml**: `lib/cascade/cascade_fsm.ml:15-20` (`decision` type), `ppx_tla/ppx_tla.ml:151, 383`
**Risk**: HIGH — corrects iter 30 audit's MISCLASSIFICATION of R-D-1.c risk from LOW to BLOCKED.
**Type**: Audit correction memo.  **Empirical finding** — attempted the fix and the build error surfaced the constraint.

## What iter 30 claimed

> **R-D-1.c**: OCaml — add `[@@deriving tla]` to `decision` type.  No semantic change; type becomes scannable by R-B-1.c validator.  Pairs with R-D-1.b adding `decision:DecisionSet` to the pair list.
>
> **Risk**: LOW — single annotation line + paired validator update.

## What iter 31 found empirically

Attempted the single-line fix in `lib/cascade/cascade_fsm.ml:20` and `.mli:37` (add `[@@deriving tla]` after the `decision` constructors).

Build error:

```
File "test/test_keeper_cascade_tla_mirror.ml", line 10, characters 19-28:
10 |     (to_tla_symbol Slot_full);
                        ^^^^^^^^^
Error: This variant expression is expected to have type decision
       There is no constructor Slot_full within type decision
```

## Root cause — ppx_tla emits unprefixed function names

```ocaml
(* ppx_tla/ppx_tla.ml:151 *)
Ast_builder.Default.ppat_var ~loc (Loc.make ~loc "to_tla_symbol")
```

The deriver always emits a function literally named `to_tla_symbol` (and `all_symbols`, `is_terminal`, etc.).  It does **not** prefix by the type name.

When `[@@deriving tla]` is applied to BOTH `provider_outcome` (line 13) and `decision` (proposed) in the same module:

1. First derive emits `let to_tla_symbol : provider_outcome -> string = function …`
2. Second derive emits `let to_tla_symbol : decision -> string = function …`
3. The second SHADOWS the first by standard OCaml binding semantics.
4. `test_keeper_cascade_tla_mirror.ml`'s `(to_tla_symbol Slot_full)` now type-resolves against the `decision`-typed function, and `Slot_full` doesn't exist in `decision`.

The same shadowing applies to `all_symbols`, `is_terminal`, `terminal_symbols`, etc.

## Why iter 30 missed this

The iter 30 audit memo reasoned by analogy:
- `provider_outcome` has `[@@deriving tla]` and builds.
- `decision` has the per-constructor `[@tla.symbol ...]` annotations.
- ∴ Adding the derive should "just work".

The reasoning ignored the *intra-module shadowing constraint*.  No prior `[@@deriving tla]` site in the codebase has TWO derived types in the same `.ml` file with overlapping function names exposed via `open`.

**Lesson**: audit risk classifications based on syntactic analogy can miss build-system semantics.  R-D-1.c should have been flagged MID minimum until empirically validated.

## R-D-1.c is BLOCKED until R-D-1.d lands

A new prerequisite candidate emerges:

| ID | Direction | Risk |
|---|---|---|
| **R-D-1.d** | ppx_tla — add `[@@deriving tla { prefix }]` option (or `[@@deriving tla] [@@tla.prefix "decision"]` attribute) emitting `decision_to_tla_symbol`, `decision_all_symbols`, `decision_is_terminal`, … instead of unprefixed names.  Backwards compatible (default behavior unchanged when no prefix). | MID — `ppx_tla.ml` deriver change (~30-50 LOC across `make_*_impl` functions), `ppx_tla` tests, downstream caller-site updates if any. |

Then R-D-1.c becomes:

> Add `[@@deriving tla { prefix = "decision" }]` to `decision` type.  Validator scans `decision_to_tla_symbol` via R-D-1.b's `provider_outcome:ProviderOutcomes, decision:DecisionSet` pair list extension.

## Adjacent unrelated lint observations during build

`dune build @check` surfaced two unrelated pre-existing errors that should *not* be attributed to this iteration's change:

1. `test/test_keeper_sandbox_plan.ml:32` — `result` applied as a function but actually a constructor; orthogonal to KCAF.
2. `Keeper_registry.registry_entry` vs tuple mismatch in some unrelated caller; orthogonal.

These appear to be live failures on main that other PRs may already be addressing.  Reported here only so future readers know the iter 31 attempt was rolled back **cleanly** and these errors persist independently of this PR.

## RFC backlog update

Updated KCAF queue:

| RFC | Status | Note |
|---|---|---|
| R-D-1.a | Open | Split `Call_err` into 3 typed variants (MID, multi-file). |
| R-D-1.b | Open | Extend validator to CONSTANT-style sets (LOW-MID). |
| R-D-1.c | **BLOCKED** | Pending R-D-1.d. |
| **R-D-1.d** | **New** | Add `prefix` option to ppx_tla deriver (MID, ppx_tla.ml). |

The cheapest *implementable* KCAF fix is now R-D-1.b (validator-side, doesn't depend on ppx).

## Why this audit memo has value despite no fix

- Documents a real constraint discovered empirically.
- Updates risk classifications based on evidence rather than analogy.
- Identifies a previously-invisible prerequisite (R-D-1.d).
- Establishes the *Loop Discipline*: when an audit claims LOW risk, an attempted fix is the cheapest way to confirm.  When the fix surfaces a hidden constraint, the audit memo is *more valuable than the fix would have been* — it prevents the same misclassification in adjacent slices.

This is the audit-correction shape that the workaround anti-pattern §CLAUDE.md flags as healthy: **prefer surfacing constraints over silencing them with workarounds**.  A naïve approach to this constraint (renaming all test references, or putting `decision` in a sub-module to break shadowing) would be a string-classifier-style workaround.  The structural fix is ppx_tla extension.

## References

- iter 30 audit: `docs/tla-audit/kcaf-d1-attempt-fsm-coverage-2026-05-12.md` — original R-D-1.c claim.
- `ppx_tla/ppx_tla.ml:151, 383` — unprefixed `to_tla_symbol` emission.
- `test/test_keeper_cascade_tla_mirror.ml:10` — the shadowing-sensitive call site.
- `lib/cascade/cascade_fsm.ml:13` — existing `[@@deriving tla]` on `provider_outcome`.
- iter 28 (#14793) — R-B-1.a closure as comparable "spec/OCaml symmetry" effort that *did* succeed (single-spec type widening, no ppx interaction).
