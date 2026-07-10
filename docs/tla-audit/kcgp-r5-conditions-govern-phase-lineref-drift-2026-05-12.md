# KCGP R-5 — KeeperConditionsGovernPhase.tla: PhaseSet projection OK; two preamble line-refs stale (first-entry audit, fixed)

**Date**: 2026-05-12 · **Iteration**: 78 (`/loop` FSM/TLA+/OCaml drift hunt) · **Phase**: R (first entry)
**Spec**: `specs/keeper-state-machine/KeeperConditionsGovernPhase.tla` (152 LOC, 2 vars, bug-model paired, liveness)
**OCaml/TS**: `lib/keeper_state/keeper_state_machine.ml` (`derive_phase`, `update_conditions`, conditions json export) · `dashboard/src/components/keeper-conditions-divergent.ts` (consumer)
**Verdict**: **clean model, two stale preamble line-refs (fixed comment-only)** — the spec's 2-element `PhaseSet = {"Running","HandingOff"}` is a *deliberate projection*, correctly disclosed (so the iter 77 KDM-style "missing Zombie" drift does NOT apply here — first spot-check of a sibling PhaseSet, came back clean). But the "Producer side" / "Wire path" sub-blocks cited `keeper_state_machine.ml:351` (the `else if c.handoff_active then HandingOff` branch — drifted +172, line 351 is now inside the `valid_transition` matrix) and `:634` (the conditions json export `"context_handoff_needed"` — drifted to ~1209; the comment self-documented an *earlier* 620→634 correction, so this was its second drift). Switched both to symbol/function anchors (iter 64 N-2.a convention). Bug-Model contract re-verified by TLC.

## What the spec is

`KeeperConditionsGovernPhase.tla` proves the liveness property behind the Agent Modal's divergent-conditions banner: `HandoffEventuallyAcknowledged == [](handoff_needed /\ phase = "Running" => <>(phase = "HandingOff"))` — if the handoff condition is observed while Running, the FSM eventually enters HandingOff. The UI surfaces divergent conditions *assuming the divergence is transient*; that assumption is a liveness claim a single observation can't verify, so the spec proves it under `WF_vars(Transition)`. Bug model removes that fairness (`FairnessBuggy == WF_vars(HandoffComplete)`) — TLC then finds a behaviour that stutters forever in `(handoff_needed ∧ phase=Running)`.

## PhaseSet spot-check (the reason this spec was picked) — clean

After iter 77 KDM R-4 found `PhaseSet` missing `"Zombie"`, I picked this spec because it also has a `PhaseSet`. Result: **no drift**. `PhaseSet == {"Running","HandingOff"}` is a *2-phase projection* of the 13-phase FSM, and the preamble says so explicitly in its *"Scope projection"* paragraph: *"spec models the 2-phase fragment (Running / HandingOff). The full 13-phase variant is out of scope here ... Adding new OCaml phases does NOT require updating this spec unless the new phase competes with HandingOff for the handoff_needed signal."* `Zombie` (terminal) does not compete for the handoff signal, so it's correctly out of scope. The structured `OCaml ↔ TLA+ mapping` table in the preamble is already symbol-anchored (`:phase`, `:context_handoff_needed`, `:update_conditions`) and accurate (`conditions.context_handoff_needed : bool` on the `conditions` record; `context_handoff_needed = context_actions.handoff` stamped in `update_conditions`).

## The two stale line-refs (sub-class 8: line-reference drift)

| Spec citation (as written) | Reality 2026-05-12 | Fix |
|---|---|---|
| `lib/keeper_state/keeper_state_machine.ml:351` — `else if c.handoff_active then HandingOff` (derive_phase) | `derive_phase` is at line **473**; its `else if c.handoff_active then HandingOff` branch is at **~523-524** (in the buffer-states block). Line 351 is inside the `valid_transition` matrix (`\| Failing, (...) -> true` etc.) — unrelated. Drift **+172**. (There are two other `else if c.handoff_active` sites — line ~1054 in a `Precondition_violation` re-trigger check, line ~1093 — neither is the derive_phase one.) | cite `derive_phase`'s `else if c.handoff_active then HandingOff` branch by name, no line number |
| `lib/keeper_state/keeper_state_machine.ml:634` — `"context_handoff_needed", \`Bool c.context_handoff_needed` (json export). *Comment*: "Verified 2026-04-20: line 620 was a stale anchor; the json serializer body shifted ~14 lines down" | The json export `; "context_handoff_needed", \`Bool c.context_handoff_needed` is at line **1209**. Line 634 is a `conditions` record default block (`launch_pending = false; ...; handoff_active = false; ...`) — unrelated. Drift to **~1209**. The 620→634 "correction" the comment records was itself superseded. | cite the `update_conditions` stamp + the conditions json export `"context_handoff_needed"` field by name; drop both line numbers and the now-pointless "shifted ~14 lines down" note |

The `dashboard/src/components/keeper-conditions-divergent.ts` consumer reference is accurate (the file exists and lists `context_handoff_needed: (v, p) => ...` among the divergent conditions) — kept, no line number needed.

## Cross-checks (pass)

| Spec element | Runtime | Status |
|---|---|---|
| `phase ∈ {"Running","HandingOff"}` (2-phase projection) | `type phase` in `keeper_state_machine.ml` — projection explicitly disclosed | ✓ |
| `handoff_needed : BOOLEAN` | `conditions.context_handoff_needed : bool` (`keeper_state_machine.ml:79`) | ✓ |
| condition stamped from auto-rule | `context_handoff_needed = context_actions.handoff` in `update_conditions` (`:565`, fn at `:547`) | ✓ |
| `Transition` (handoff_needed ∧ Running → HandingOff) | `derive_phase`'s `else if c.handoff_active then HandingOff` branch (`:~523`) | ✓ |
| consumer surfaces the divergent condition | `dashboard/src/components/keeper-conditions-divergent.ts` (`context_handoff_needed: (v,p) => ...`) | ✓ |
| `.cfg` / `-buggy.cfg` | both present | ✓ |
| Bug-Model contract | clean = no error (4 distinct states); buggy = `HandoffEventuallyAcknowledged` violated (temporal counterexample) — re-verified this PR | ✓ |

## Sub-class placement & follow-up

- Drift = **sub-class 8 (line-reference drift)**, OCaml side — and the *second* time `KeeperConditionsGovernPhase.tla`'s wire-path anchor has drifted (620→634→1209). The fix (symbol anchors, no line numbers) is the same as iters 64 N-2.a / 70 KCB / 77 KDM, and is now applied to *both* the producer block and the wire-path block so this anchor can't rot again.
- `PhaseSet` spot-check: **clean** — KeeperConditionsGovernPhase's 2-element set is a disclosed projection, not a stale full-FSM list. (Recommendation: when entering specs with a full-13-phase `PhaseSet` — KeeperDwellMonotone was one, fixed iter 77 — re-check the count against `keeper_state_machine.ml:type phase`. Projections like this one and KeeperReconcileLiveness are fine.)
- No follow-up PR owed. `specs/INDEX.md` regenerated (KCGP content-hash bump `f70bcf64b7d8 → d3393c4367e8`). Comment-only spec change — model identical, but TLC was re-run anyway (clean + buggy both as expected).
