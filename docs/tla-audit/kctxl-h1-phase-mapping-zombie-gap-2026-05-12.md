# KCtxL H-1 Audit — Phase mapping table missing Zombie (silent unmodeled)

**Iteration**: 47 (/loop FSM/TLA+/OCaml drift hunt — first KCtxL entry, Phase H)
**Date**: 2026-05-12
**Spec**: `specs/keeper-state-machine/KeeperContextLifecycle.tla:57-86` (mapping table) + 427 LOC total
**Risk**: LOW — Zombie is terminal-terminal (post-Dead), so omission is behaviorally safe; but the spec documentation **silently lags** KSM phase evolution.  iter 38 KCL E-1 pattern (cross-spec staleness) reincarnated at the doc level.
**Type**: Audit-only.

## What KCtxL is

`KeeperContextLifecycle.tla` (427 LOC) is a context-identity / checkpoint / compaction observer.  It maps the 13-phase KSM FSM onto a 7-symbol projection alphabet for context-lifecycle invariants (S1-S7 safety + L1-L3 liveness).

## The mapping table (KCtxL.tla:67-77)

```
spec name         ↔ OCaml constructor   (phase_to_string output)
------------------+----------------------+----------------------
"idle"            ↔ Offline               ("offline")
"running"         ↔ Running               ("running")          *
"compacting"      ↔ Compacting            ("compacting")       *
"overflow_retry"  ↔ Overflowed            ("overflowed")
"done"            ↔ Stopped               ("stopped")
"error"           ↔ Failing | Crashed     ("failing"|"crashed")
"dead"            ↔ Dead                  ("dead")             *
    * = spec name and wire format coincide.
```

Plus line 83 "Unmodeled here (covered in companion specs)":
```
HandingOff, Draining, Paused, Restarting
```

**Total**: 8 mapped (one entry is a 2-OCaml-collapse for `error`) + 4 explicitly unmodeled = **12 OCaml phases accounted for**.

## OCaml ground truth (keeper_state_machine.ml:6-19)

```ocaml
type phase =
  | Offline
  | Running
  | Failing
  | Overflowed
  | Compacting
  | HandingOff
  | Draining
  | Paused
  | Stopped
  | Crashed
  | Restarting
  | Dead
  | Zombie   (* 13th phase *)
```

**13 phases**.  KCtxL documents 12.  **Zombie is silently missing** — not in the mapping table, not in the unmodeled list.

## Why this happened

Iter 3-4 work added the Zombie phase as part of the supervisor liveness audit (PR #14702 closed iter 3 derive_phase priority chain, PR #14707 added `ZombieIsForever` / `ZombieRequiresTerminalFailureLatched` invariants — KSM A-4).  KCtxL was authored *earlier* (issue #8701 explicit mapping per spec line 57 comment) and its mapping table predates Zombie's addition to the KSM type.

This is the **iter 38 KCL E-1 pattern at the documentation layer**: cross-spec staleness when one spec's vocabulary evolves but observer specs don't follow.  KCL E-1 surfaced at the **TLA+ set** layer (`TurnPhaseSet` 5 vs 7 members).  KCtxL H-1 surfaces at the **doc-only mapping table** layer — the spec's `Phases` set (`{idle, running, compacting, overflow_retry, done, error, dead}`) is structurally coherent, just incomplete docs.

## Why production stays correct (today)

- **Zombie is terminal-terminal**: a Zombie keeper has already passed through Dead (per keeper_state_machine.ml derive_phase priority chain) and cannot generate context-lifecycle events (StartTurn, CompactionCompletes, etc.).  KCtxL's `Init` initializes all keepers to `"idle"`; no action transitions into a "zombie" phase because the spec doesn't model that vocabulary.
- **KSM's own spec** carries Zombie invariants (`ZombieIsForever`, `ZombieRequiresTerminalFailureLatched`, both in #14707).  KCtxL's projection collapses Zombie into nothing — but the safety surface lives in KSM, not in KCtxL.
- **Companion specs cover the gap**: line 83's "unmodeled HandingOff/Draining/Paused/Restarting" list points readers to sibling specs.  Zombie should be in that list or in the mapping table with a "(terminal-terminal, no context events)" note.

So this is a **doc-staleness gap**, not a runtime bug.  But it's the second instance of a class observed at KCL E-1 (#14822 audit, #14824 fix) — proving the pattern is recurring, not isolated.

## R-B-1.c validator gap

The R-B-1.c chain (iter 19→43) catches drift between OCaml constructor names and TLA+ set members at the `[@@deriving tla]` level.  But KCtxL's `Phases` set is NOT annotated against OCaml's `phase` type — it's a *deliberate projection* with explicit collapse (`error ↔ Failing | Crashed`).  Validators that compare set members directly would false-positive on the intentional 2:1 collapse.

This is the **same coverage limit** as iter 38 KCL Finding 2 (`KcafPhaseSet` 3:6 collapse).  The validator chain catches *bare* drift but not *deliberate-projection-with-stale-mapping-table* drift.

## Three RFC candidates

| ID | Direction | Risk |
|---|---|---|
| **R-H-1.a** | KCtxL header — add Zombie to line 83 unmodeled list OR to mapping table with explicit "(terminal-terminal, no context events possible)" note.  Doc-only.  Matches iter 27/35/37/39 honest-doc pattern. | LOW (doc only) |
| **R-H-1.b** | Sweep all observer specs (KeeperGenerationLineage, KeeperReconcileLiveness, KCL, etc.) for mapping tables that pre-date Zombie addition.  Add Zombie line to each that's missing.  Multi-spec audit + fix. | LOW (doc-only sweep, but multi-file) |
| **R-H-1.c** | Doc-validation script — for each observer spec with a mapping table, verify every OCaml `phase` constructor is named (either mapped or in unmodeled list).  bash + AST-ish parsing.  Extends R-B-1.c chain to doc-only mapping comments. | MID — parsing TLA+ comments is fragile; might use sentinel markers like `\* OCaml ↔ TLA+ mapping`. |

**Recommended**: R-H-1.a (immediate single-spec fix) + queue R-H-1.b sweep as separate iter to find other Zombie-missing observer docs.  R-H-1.c is structural but premature without evidence of more than 2-3 instances.

## Empirical observations

- **5 phases coincide with wire format** per spec line 65-76 footnote (`"running"`/`"compacting"`/`"dead"` marked with `*`).  KCtxL aim is to NOT bind to wire format, but coincidence is fine.  Zombie's wire format is `"zombie"` — adding to mapping with that note would be consistent.
- **`error` is the only 2:1 collapse**.  Failing + Crashed collapse because they have indistinguishable behavior for context-lifecycle invariants.  Zombie would be a *0:1 unmodeled* not a collapse — different category.
- **Mapping table format**: 3-column markdown-style with `↔` separator + wire-format coincidence flag.  R-H-1.a addition fits the existing format trivially.

## Out-of-scope

- R-H-1.a apply — separate doc-only PR (iter 48 candidate).
- R-H-1.b multi-spec sweep — needs grep across observer specs for "mapping" comment headers.
- R-H-1.c validator — premature without recurrence evidence.
- KCtxL liveness audit (L1-L3) — deferred to future KCtxL iter (H-2?).
- KCtxL `CompactionFailed` action explicitly excluded from `Next` (line 304-310 comment "infinite compacting ↔ overflow_retry cycle"); the retry-budget refinement mentioned line 200-204 is a separate KCtxL deepening, not part of H-1.

## References

- KCtxL spec §1-86 (Purpose + mapping table), §86 (`Phases` set definition).
- KSM `keeper_state_machine.ml:6-19` — 13-constructor `phase` type.
- iter 3 A-3 derive_phase priority chain (#14702 ✓ merged) — Zombie introduction context.
- iter 4 A-4 terminal phase reject (#14707) — `ZombieIsForever` / `ZombieRequiresTerminalFailureLatched` invariants added to KSM.
- iter 38 KCL E-1 (`kcl-e1-cross-spec-projection-drift-2026-05-12.md`) — first cross-spec staleness audit; H-1 is the doc-layer analog.
- iter 39 R-E-1.c (#14824 ✓ merged) — KcafPhaseSet doc-annotation precedent; R-H-1.a takes the same shape (single-spec inline doc addition).
- iter 27/35/37/39 honest-doc pattern — 4 prior datapoints, R-H-1.a would be the 5th.
