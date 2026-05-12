# KDM R-4 — KeeperDwellMonotone.tla: PhaseSet missing "Zombie" + Implementation-mapping line-refs stale (first-entry audit, fixed)

**Date**: 2026-05-12 · **Iteration**: 77 (`/loop` FSM/TLA+/OCaml drift hunt) · **Phase**: R (first entry)
**Spec**: `specs/keeper-state-machine/KeeperDwellMonotone.tla` (159 LOC, 3 vars, bug-model paired)
**OCaml/TS**: `lib/keeper/keeper_registry.ml` (producer) · `dashboard/src/components/keeper-detail-page.ts` + `keeper-detail-shell.ts` + `keeper-phase-indicator.ts` (consumer) · `dashboard/src/api/keeper.ts` (`fetchKeeperTransitions`)
**Verdict**: **two real drifts, both fixed in this PR** — (1) `PhaseSet` listed only 12 of the 13 `type phase` constructors (`"Zombie"` missing) despite the spec's own comment saying it was present; (2) the `Implementation mapping` block cited `keeper_registry.ml:919` (drifted +1658 — the `wall_clock_at_decision = now` stamp is at ~line 2577; line 919 is `packed_compaction_stage_label`, unrelated) and three dashboard files that had been refactored away (`keeper-detail.ts` is now a 15-line shim; the `phaseEnteredAtSec` `useState` moved to `keeper-detail-page.ts`). Core safety (`DwellNonNegative`) was correct throughout — both drifts are model-completeness / navigability, not a logic bug.

## What the spec is

`KeeperDwellMonotone.tla` models the minimal clock + phase-entry-stamp relationship behind the Agent Modal's "Running for 2h 20m" dwell indicator: `DwellNonNegative == entered_at <= now`. Discipline points: (1) the clock is monotonic; (2) every phase transition does `entered_at := now` (no stale carry-over, no future stamp). Bug model `BuggyEntryInFuture` does `entered_at' = now + 1` — TLC catches it (counterexample `now=1, phase="Running", entered_at=2`).

## Drift 1 — `PhaseSet` missing `"Zombie"` (sub-class 2: drift)

The OCaml `keeper_state_machine.ml:6-19` has **13** `type phase` constructors: `Offline | Running | Failing | Overflowed | Compacting | HandingOff | Draining | Paused | Stopped | Crashed | Restarting | Dead | Zombie`. The spec's `PhaseSet` literal listed only the first **12** — `"Zombie"` absent — even though the comment directly above it said *"13-phase FSM ... Zombie added iter 4 #14707, terminal-terminal — see PhaseSet below"*. The comment was right; the set was stale.

**Effect**: `DwellNonNegative` is phase-agnostic (it constrains `entered_at`/`now` only), so the safety result is unaffected. But `TypeOK` excluded `phase = "Zombie"` and the `Transition` action never explored transitions into/out of Zombie — the spec silently under-modelled a terminal phase. **Fix**: added `"Zombie"` to `PhaseSet`; updated the comment to record the iter 77 R-4 correction.

**TLC re-run (this PR)** — verified the Bug-Model contract still holds with the 13th phase:
- Clean (`KeeperDwellMonotone.cfg`): `Model checking completed. No error has been found.` — 3472 states generated, 273 distinct, depth 8, max outdegree 13 (= 12 other phases + 1 tick — consistent with the 13-phase set). ✓
- Buggy (`KeeperDwellMonotone-buggy.cfg`): `DwellNonNegative` violated, counterexample trace `now=1, phase="Running", entered_at=2` (≈ depth 2-3). ✓

## Drift 2 — `Implementation mapping` block stale on all three sites (sub-class 8: line-reference drift)

| Spec citation (as written) | Reality on 2026-05-12 | Fix |
|---|---|---|
| `lib/keeper/keeper_registry.ml:919` — `Keeper_transition_audit.record_transition { ...; wall_clock_at_decision = now; ... }` | `wall_clock_at_decision = now` is at **~line 2577**; line 919 is `let packed_compaction_stage_label` (compaction-stage diagnostics, unrelated). Drift **+1658**. | Cite by symbol: "the `Keeper_transition_audit.record_transition { ...; wall_clock_at_decision = now; ... }` record built at each transition apply" — no line number (iter 64 N-2.a convention) |
| `dashboard/src/components/keeper-detail.ts:1167-1168` — `const [phaseEnteredAtSec, ...] = useState<number \| null>(null)` from `fetchKeeperTransitions(...).transitions[0].wall_clock_at_decision` | `keeper-detail.ts` is now a **15-line file** (re-export shim). The `phaseEnteredAtSec` `useState` lives in **`dashboard/src/components/keeper-detail-page.ts`** (`const [phaseEnteredAtSec, setPhaseEnteredAtSec] = useState<number \| null>(null)`), sourced from `fetchKeeperTransitions` in **`dashboard/src/api/keeper.ts`**, threaded through `keeper-detail-shell.ts` into `KeeperPhaseAndStage` | Re-pointed to `keeper-detail-page.ts` / `keeper-detail-shell.ts` / `dashboard/src/api/keeper.ts`; no line numbers |
| `dashboard/src/components/keeper-phase-indicator.ts:113` — `formatDuration(Math.max(0, Date.now()/1000 - phaseEnteredAtSec))` | Now at **line 114**, restructured into a `dwellText` const guarded by `typeof phaseEnteredAtSec === 'number' && Number.isFinite(phaseEnteredAtSec)`; clamp body unchanged (`formatDuration(Math.max(0, Date.now() / 1000 - phaseEnteredAtSec))`) | Cite the `dwellText` expression in `keeper-phase-indicator.ts`; no line number |

The clamp's *behaviour* is intact (the defense-in-depth `Math.max(0, ...)` still guards a misbehaving clock); only the file/line citations had rotted. The spec's claim "this is independent of the spec — the spec ensures the producer side is correct so the clamp should never fire" remains accurate.

## Cross-checks (pass)

| Spec element | Runtime | Status |
|---|---|---|
| `PhaseSet` (now 13) | `type phase` in `keeper_state_machine.ml` (13 constructors) | ✓ after this PR |
| producer stamps `entered_at := now` | `Keeper_transition_audit.record_transition { ...; wall_clock_at_decision = now; ... }` in `keeper_registry.ml` — `now` from `Time_compat.now ()` | ✓ |
| consumer reads latest transition's stamp | `keeper-detail-page.ts` `phaseEnteredAtSec` ← `fetchKeeperTransitions` (`dashboard/src/api/keeper.ts`) ← `wall_clock_at_decision` | ✓ |
| frontend never shows negative dwell | `keeper-phase-indicator.ts` `formatDuration(Math.max(0, Date.now()/1000 - phaseEnteredAtSec))` | ✓ |
| `.cfg` / `-buggy.cfg` | both present (+ a past-run TTrace file) | ✓ |
| Bug-Model contract | clean = no error, buggy = `DwellNonNegative` violated — re-verified this PR | ✓ |

## Sub-class placement & follow-up

- Drift 1 = **sub-class 2 (drift)** — the literal `PhaseSet` lagged its own comment and the OCaml `type phase`.
- Drift 2 = **sub-class 8 (line-reference drift)** — the producer ref drifted +1658, the consumer refs survived a multi-file dashboard refactor pointing at a now-15-line shim.
- No follow-up PR owed. `specs/INDEX.md` regenerated (KDM content-hash bump `805be4907879 → 69416fba4415`).
- This is the first audited spec where a *frontend* refactor (component split into `*-page.ts` / `*-shell.ts`) had silently invalidated a spec citation — worth noting that the line-ref drift class isn't OCaml-only; TS component renames hit it too. The fix (symbol/file anchors, no line numbers) is the same.
