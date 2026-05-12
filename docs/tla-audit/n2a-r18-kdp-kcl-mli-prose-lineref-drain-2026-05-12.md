# N-2.a R-18 — KDP + KCL `.mli:NNN` / prose `line N` cleanup (iter 92 follow-up; closing the catalogued `.mli` sites + the prose-form "Authoritative write points" block that Rule 1 missed)

**Date**: 2026-05-12 · **Iteration**: 93 (`/loop` FSM/TLA+/OCaml drift hunt) · **Phase**: doc-cleanup (closing iter 92's named follow-up)

## What this is

iter 92 #14996 added `audit-tla-ml-line-refs.sh` Rule 2 — a zero-tolerance whole-file scan for the compact `\.ml:[0-9]` form. Two known sites were *explicitly excluded* from Rule 2's scope (deliberately, with the trade-off documented in the script header):

1. `KeeperCompositeLifecycle.tla:25` — `Keeper_state_machine.mli:139-144 [type event / Context_measured]` + nearby `lines 131-136 / line 139 / line 144` prose anchors.
2. `KeeperDecisionPipeline.tla:23` — `(mli mirror at keeper_registry.mli:49-53)`.

And the same KDP preamble carries a separate prose-form block (`line 493 / 515 / 535 / 575 / 590 / 614`, the six "Authoritative write points") which Rule 1's regex (`\[func\][^,]*line[s ]+N`) *also* misses — Rule 1 requires the function name to be bracketed (`[mark_turn_started]`), but the block uses a bare name (`- mark_turn_started ... line 493`). Rule 2 (compact form) doesn't catch it either.

This PR drains all of these by hand, in two files, with no model-body change.

## Why these were excluded from Rule 2

- **`.mli` files** are interface declarations — typically ~300-400 LOC at masc-mcp's current scale and they don't *grow* the way `.ml` files do (they're appended only when a new public symbol is added, not when an implementation expands). So the *growth-driven* drift Rule 2 targets doesn't apply to them. Rule 1 already treats `.mli` as a fallback (it uses `.mli` only if the preamble cites no `.ml` at all).
- **Prose form with a bare name** (`line 493 -- Decision_undecided` vs `[mark_turn_started] ... line 493 -- ...`) is a third drift class, distinct from Rule 1's bracketed-name prose and Rule 2's compact form. A third regex was deliberately deferred — drift here is already at +1094 lines on main (see "Drift severity" below), so a manual symbol-anchor pass is the smaller and safer fix.

## Drift severity (proof that the cleanup matters)

KDP's "Authoritative write points" was last verified 2026-04-28 (`#11641` sibling refresh). Current line locations in `lib/keeper/keeper_registry.ml` on origin/main (a0c3a718f):

| cited line (2026-04-28) | actual line (origin/main 2026-05-12) | drift |
|---|---|---|
| 493 `mark_turn_started` | 1587 | **+1094** |
| 515 `mark_turn_measurement` | 1645 | **+1130** |
| 535 `set_turn_decision_stage` | 1719 | **+1184** |
| 575 `prepare_turn_retry_after_compaction` | 1848 | **+1273** |
| 590 `mark_turn_gate_rejected_by_name` | 1867 | **+1277** |
| 614 `mark_turn_finished` | 1893 | **+1279** |

All six function bindings still exist with the cited names — that part of the anchor is fine. Only the line numbers rotted. This is exactly the failure mode iter 64 N-2.a was meant to prevent, and exactly the failure mode the cleanup of mapping-table compact-form citations in iter 84/85/91 (`6c1d427d8`) chose symbol anchors *to avoid*.

KCL's `Keeper_state_machine.mli:139-144` block has smaller drift (`type event` at 163, `Context_measured` at 168 on current main — a +24/+24 drift respectively), but its surrounding text already self-narrates "lines 131-136 reference... starts at line 139 with [Context_measured] at line 144" — three line numbers in adjacent prose, all decayable on every `.mli` edit.

## What changed

Two files, **comments-only**, no `VARIABLES` / `Action` / `Invariant` / `Init` touched.

### `specs/keeper-state-machine/KeeperDecisionPipeline.tla`

(a) Line 23 — `(mli mirror at keeper_registry.mli:49-53)` → `(mli mirror at keeper_registry.mli -- type decision_stage_active)`. The symbol exists (`keeper_registry.mli:273` `type decision_stage_active =`).

(b) "Authoritative write points" block (lines 29-37) — drop `line NNN` from each of 6 entries; rewrite the verification preamble to make the citation-by-symbol contract explicit and re-date to 2026-05-12. Result:

```
(* Authoritative write points (lib/keeper/keeper_registry.ml).             *)
(* Cite by symbol -- iter 64 N-2.a (`*.ml` files grow; line refs drift on  *)
(* every edit while function names are stable identifiers). Verified       *)
(* against main as of 2026-05-12 (iter 93 line-ref drain; #11641 sibling   *)
(* refresh; iter 92 #14996 closed the `\.ml:NNN` colon-form guard).        *)
(*   - mark_turn_started                       -- Decision_undecided          *)
(*   - mark_turn_measurement                   -- sets measurement_bound      *)
(*   - set_turn_decision_stage                 -- Decision_guard_ok | _selected *)
(*   - prepare_turn_retry_after_compaction     -- reset to Decision_guard_ok   *)
(*   - mark_turn_gate_rejected_by_name         -- Decision_gate_rejected       *)
(*   - mark_turn_finished                      -- reset to Decision_undecided  *)
```

### `specs/keeper-state-machine/KeeperCompositeLifecycle.tla`

Lines 24-29 — six lines covering `Keeper_state_machine.mli:139-144` and three adjacent `line N` references rewritten to anchor by `[Context_measured]` / `[type event]` symbols only; the explanation that the spec uses symbols (because the OCaml compiler keeps names honest while line numbers don't) is moved inline.

```
\*   1. shared_measurement is the coordination hub (Context_measured event,
\*      Keeper_state_machine.mli -- [Context_measured] constructor of
\*      [type event], auto_rules_summary). Cite by symbol -- iter 64 N-2.a
\*      (line numbers drift on every edit; [type event] / [Context_measured]
\*      are stable identifiers, the OCaml compiler keeps them honest).
\*      Adjacent NoDrainTransition / GhostDispatch *.mli docstring callouts
\*      are anchored similarly by name, not by line number.
```

## Verification

- `grep -nE '\.mli?:[0-9]|line [0-9]' specs/keeper-state-machine/KeeperDecisionPipeline.tla specs/keeper-state-machine/KeeperCompositeLifecycle.tla` → empty.
- `bash scripts/audit-tla-ml-line-refs.sh` → `line-ref audit clean: 0 citation(s) verified across 34 spec(s).` (Rule 1 still the only active rule on origin/main; Rule 2 is in flight on PR #14996 and would also pass — these `.mli:NNN` sites were the two known exemptions Rule 2 doesn't currently catch.)
- `bash scripts/gen-tla-index.sh > specs/INDEX.md` — two hash deltas (`49e687b83457 → 7863e87c2acd` for KCL; `41557f9e0eb0 → 5a68dbb60588` for KDP), both from header-comment text change. Model body byte-identical.
- TLC KDP clean: 14 states generated, 7 distinct, depth 6 — unchanged.
- Comments-only edits — no behavioural verification needed for the other 4 KCL cfgs or the 1 KDP buggy cfg; bytes between `==== MODULE` and `====` unchanged.

## Not a workaround

CLAUDE.md §워크어라운드 거부 기준 #2 ("string/substring 분류기 보강") targets *runtime* string classifiers added where a typed variant would do — `String.starts_with ~prefix:"completion_contract_violation:"` and the like. This is a *documentation hygiene* fix: the iter 64 N-2.a convention is to cite by symbol because OCaml's compiler tracks symbol-name renames at the type level (a renamed binding fails to build, a moved binding still builds at its new line), and this PR makes two specs follow that convention. The "structural" fix is N-2.a itself; this PR is one of the routine drain-the-baseline iterations that the iter-74 follow-up posture explicitly accepts.

## Follow-up

- The third drift class (prose form with bare name, no brackets) could in principle be added as Rule 3 to `audit-tla-ml-line-refs.sh` — a whole-file scan for `^\s*\*?\s*-\s+[a-z_]+\s+line\s+\d+`. Currently zero sites in `specs/keeper-state-machine/*.tla` after this PR. Worth re-checking on the next iteration that introduces a new preamble citation table; pre-emptive Rule 3 is not warranted yet (Rule 3 adds maintenance cost; zero sites today; the absence of a guard didn't generate new ones in the past iter-92-cleared subdir).
- `keeper_unified_turn.ml`'s `run_keeper_cycle` reverse-citation block still says `Spec line 3 ... "[run_keeper_cycle] (line 1042+)"` — owed since iter 91. Best landed in a future OCaml-touching keeper PR (so a single commit can update the comment in lockstep with whatever it's annotating).
- Other spec trees (`specs/boundary/`, `specs/bug-models/`, `specs/auth/`, `specs/admission-queue/`, `specs/keeper-turn-fsm/`, `specs/task-lifecycle/`) carry ~40 `\.ml:[0-9]` refs and never adopted N-2.a. Extending the convention there would need a baseline file (precedent: `audit-tla-annotation-drift.sh --baseline`). Out of this PR's scope.
