# KLP R-7 — KeeperLaunchPending.tla: preamble line-refs drifted +100..+1000 lines; symbol-anchored (first-entry audit, fixed)

**Date**: 2026-05-12 · **Iteration**: 80 (`/loop` FSM/TLA+/OCaml drift hunt) · **Phase**: R (first entry)
**Spec**: `specs/keeper-state-machine/KeeperLaunchPending.tla` (149 LOC, 3 vars, bug-model paired)
**OCaml**: `lib/keeper/keeper_state_machine.ml` (`derive_phase`, `update_conditions` `Fiber_started` arm, conditions json export) · `lib/keeper/keeper_registry.ml` (`register_offline`, `mark_dead`)
**Verdict**: **model correct; preamble's ~8 line-number citations all stale (drift +100 to +1000), fixed comment-only**. The spec body (`launch_pending`/`fiber_alive`/`phase` vars, `Init`, `FiberStart`/`MarkDead`/`Done`, `FiberStartedWithoutClearing` bug action, `LaunchPendingExclusive`/`PhaseConsistent` invariants) is byte-identical and matches the runtime; TLC re-verified (clean = no error, buggy = `SafetyInvariant` violated). Only the preamble's OCaml citations had rotted — and `keeper_registry.ml` has grown ~1000 lines since they were written, so the `keeper_registry.ml:340`/`:407` anchors now point ~950-1040 lines off.

## What the spec is

`KeeperLaunchPending.tla` models the `launch_pending : bool` lifecycle for the 3-phase fragment `{Offline, Running, Dead}` — the `derive_phase` Offline branch (`else if c.launch_pending && not c.fiber_alive then Offline`) was the only branch without a phase-derivation spec. Key invariant: `LaunchPendingExclusive == ~(launch_pending /\ fiber_alive)` — the pre-launch flag and the alive flag are never both set. Bug action `FiberStartedWithoutClearing` sets `fiber_alive' = TRUE` but leaves `launch_pending' = TRUE` (drift: a future `update_conditions` refactor omitting the `launch_pending = false` field). The phase still resolves to Running (the Offline branch demands `~fiber_alive`), so the drift is invisible to phase consumers but visible in the conditions JSON — exactly the kind of silent observability drift the spec defends against. TLC: clean = no error; buggy = `Invariant SafetyInvariant is violated`. (Re-verified this PR.)

## What drifted (sub-class 8: line-reference drift — large scale)

| Spec citation (as written) | Actual location 2026-05-12 | Drift | Fix |
|---|---|---|---|
| `keeper_state_machine.ml:393-394` — `else if c.launch_pending && not c.fiber_alive then Offline` | line **501** (inside `derive_phase`, which starts at line 473) | **+108** | cite `derive_phase`'s `else if c.launch_pending && not c.fiber_alive then Offline` branch by name |
| `KeeperReconcileLiveness:88-101` (sibling spec line range) | `KeeperReconcileLiveness.tla`'s `DerivePhase` is at ~lines 88-101 (still roughly there — least drifted) | ~0 | cite `KeeperReconcileLiveness's DerivePhase` by name |
| `keeper_registry.ml:340` — `register_offline` (set `launch_pending = true`) | `let register_offline` at line **1288**, `launch_pending = true` at line **1291** | **+948** | cite `keeper_registry.ml — register_offline` by name |
| `keeper_state_machine.ml:520` / `:518-532` — `Fiber_started` event handler | the `Fiber_started ->` arm of `update_conditions` at line **613**; the `{ c with launch_pending = false; fiber_alive = true; ... }` record at ~**627-629** | **+93..+97** | cite `update_conditions`' `Fiber_started` arm by name |
| `keeper_registry.ml:407` / `:400-413` — Dead transition (reset both flags) | `let mark_dead` at line **1442**; `launch_pending = false` / `fiber_alive = false` at ~**1472-1473** | **+1035..+1042** | cite `keeper_registry.ml — mark_dead` by name |
| `keeper_state_machine.ml:709` — json export of `launch_pending` | `[ "launch_pending", \`Bool c.launch_pending` at line **1204** | **+495** | cite the conditions json export `"launch_pending"` field by name |
| `keeper_registry.ml:337-344` — `register_offline` (Init mirror) | `let register_offline` at **1288** | **+944** | symbol anchor |
| "derive_phase priority 9 (Running)" | the Running branch is `else if fiber_alive` near the bottom of `derive_phase` — "priority 9" is approximate and brittle | n/a | cite `derive_phase`'s `fiber_alive` branch by name, no priority number |

## Cross-checks (pass)

| Spec element | Runtime | Status |
|---|---|---|
| `Init` (launch_pending=TRUE, fiber_alive=FALSE, phase=Offline) | `register_offline` builds `default_conditions` with `launch_pending = true; restart_budget_remaining = true`; `derive_phase` → `Offline` (the `launch_pending && ~fiber_alive` branch at line 501) | ✓ |
| `FiberStart` (launch_pending'=FALSE, fiber_alive'=TRUE, phase'=Running) | `update_conditions`' `Fiber_started` arm: `{ c with launch_pending = false; fiber_alive = true; ... }`; `derive_phase` → `Running` (the `fiber_alive` branch) | ✓ |
| `MarkDead` (launch_pending'=FALSE, fiber_alive'=FALSE, phase'=Dead) | `keeper_registry.ml`'s `mark_dead`: resets `launch_pending = false; fiber_alive = false`, phase → `Dead` | ✓ |
| `LaunchPendingExclusive` (the two flags never both TRUE) | `update_conditions`' `Fiber_started` arm sets `launch_pending = false` *in the same record* as `fiber_alive = true` — atomic, so they're never both TRUE | ✓ — the bug action's exact failure mode is "this record drops the `launch_pending = false` field" |
| `FiberStartedWithoutClearing` not present in runtime | the `Fiber_started` arm does set `launch_pending = false` | ✓ — runtime doesn't exhibit the modelled drift |
| conditions JSON surfaces `launch_pending` | `[ "launch_pending", \`Bool c.launch_pending` in `keeper_state_machine.ml` (line 1204) — so the drift *would* be observable | ✓ — matches the spec's "visible to anyone reading conditions" claim |
| `PhaseSet == {"Offline","Running","Dead"}` (3-phase projection) | disclosed in the preamble ("the full 13-phase variant is out of scope") | ✓ — like KCGP (iter 78), this is a deliberate projection, not a stale full set; no Zombie-sync needed |
| `.cfg` / `-buggy.cfg` | both present | ✓ |
| Bug-Model contract | clean = no error; buggy = `Invariant SafetyInvariant is violated` — re-verified this PR | ✓ |

## Sub-class placement & follow-up

- Drift = **sub-class 8 (line-reference drift)** — the most-drifted instance the loop has found so far (`keeper_registry.ml:407 → mark_dead@1442` is +1035 lines). Cause: `keeper_registry.ml` is one of the repo's largest files and has roughly doubled since this spec's preamble was written. Fix: every OCaml ref now cited by function/arm name (iter 64 N-2.a convention), with a top-of-preamble note recording the convention switch + drift magnitude.
- `PhaseSet` spot-check: **clean** (3-phase projection, disclosed) — second sibling after KCGP iter 78 that came back clean. Pattern holding: only full-13-phase `PhaseSet`s need the `type phase` cross-check (KeeperDwellMonotone was the one that needed it, fixed iter 77).
- No follow-up PR owed. Comment-only spec change — model body byte-identical; `specs/INDEX.md` regenerated (KLP content-hash bump `29a782dc0677 → b40572292792`). The spec is in the `make -C specs check-clean` runner (not `KNOWN_FAILURES`); CI re-checks it.
- **Note on the line-ref drift class going forward**: KeeperLaunchPending, KeeperDwellMonotone (iter 77), KeeperConditionsGovernPhase (iter 78), KeeperOutcomesConservation (iter 79) — four consecutive first-entry audits, all found stale line numbers in the preamble. The pattern is now empirically: *any spec preamble older than ~iter 64 that cites `keeper_state_machine.ml:NNN` or `keeper_registry.ml:NNN` should be assumed drifted.* A bulk sweep (grep `specs/keeper-state-machine/*.tla` for `\.ml:[0-9]` and symbol-anchor all hits in one PR) is a candidate follow-up if the per-spec rate stays this high.
