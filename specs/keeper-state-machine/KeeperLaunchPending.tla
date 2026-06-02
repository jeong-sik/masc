---- MODULE KeeperLaunchPending ----
\* Pre-launch lifecycle for `lib/keeper/keeper_state_machine.ml`'s Offline
\* branch.  This spec closes Note A drift identified during Cycle 24 /
\* Tier C1 Phase 0:
\*
\*   keeper_state_machine.ml — derive_phase's
\*     `else if c.launch_pending && not c.fiber_alive then Offline`
\*     branch (the Offline branch, low priority — it only fires when
\*     no higher-priority condition holds)
\*
\*   was the only `derive_phase` branch lacking a phase-derivation
\*   spec.  Sibling specs (KeeperReconcileLiveness's DerivePhase,
\*   KeeperConditionsGovernPhase, KeeperCompactionLifecycle, ...)
\*   together cover every other priority.  This spec fills that gap.
\*
\* All OCaml refs below are cited by function/arm name, not line number
\* — iter 64 N-2.a convention; the preamble's previous line anchors had
\* drifted by +100..+1000 lines (keeper_registry.ml had grown ~1k lines).
\* See docs/tla-audit/klp-r7-launch-pending-lineref-drift-2026-05-12.md
\*
\* Runtime entities modelled (lifecycle of `launch_pending : bool`):
\*
\*   Set TRUE  : keeper_registry.ml — register_offline (the
\*               default_conditions record with launch_pending = true).
\*               Invoked at keeper registration *before* the fiber has
\*               been spawned.  Pairs with restart_budget_remaining = TRUE.
\*   Clear FALSE
\*     in FSM  : keeper_state_machine.ml — update_conditions' Fiber_started
\*               arm (`{ c with launch_pending = false; fiber_alive = true; ... }`).
\*               Fiber has actually started; pre-launch is no longer pending.
\*     on death: keeper_registry.ml — mark_dead (resets
\*               launch_pending = false; fiber_alive = false).  Keeper is
\*               permanently dead, all flags reset.
\*
\* Scope projection: this spec models only the launch_pending /
\* fiber_alive / phase relationship for the 3-phase fragment
\* {Offline, Running, Dead}.  The full 13-phase variant is out of
\* scope (other specs cover the remaining branches).
\*
\* Failure mode the bug action targets:
\*
\*   FiberStartedWithoutClearing — the fiber actually starts
\*   (fiber_alive flips TRUE) but the launch_pending flag is NOT
\*   reset.  In OCaml this would happen if a future refactor of
\*   `update_conditions` for the `Fiber_started` event omits the
\*   `launch_pending = false` field.  The visible symptom is a
\*   keeper that runs *and* reports launch_pending=true in JSON,
\*   confusing supervisors (per keeper_registry.ml polls; the
\*   conditions json export `"launch_pending", \`Bool c.launch_pending`
\*   in keeper_state_machine.ml surfaces it).  Phase would still
\*   resolve to Running because the Offline branch only fires when
\*   fiber_alive=FALSE — so the drift is silent unless caught here.
\*
\* Bug-Model contract (CLAUDE.md software-development.md):
\*   Spec      under KeeperLaunchPending.cfg       => TLC: no error.
\*   SpecBuggy under KeeperLaunchPending-buggy.cfg => TLC: invariant
\*                                                     violated.
\* Both must hold.

EXTENDS TLC

VARIABLES
    launch_pending,
    fiber_alive,
    phase

vars == << launch_pending, fiber_alive, phase >>

PhaseSet == { "Offline", "Running", "Dead" }

TypeOK ==
    /\ launch_pending \in BOOLEAN
    /\ fiber_alive    \in BOOLEAN
    /\ phase          \in PhaseSet

\* Init mirrors keeper_registry.ml's register_offline:
\*   default_conditions {launch_pending = true; restart_budget_remaining = true}
\*   derive_phase -> Offline.
Init ==
    /\ launch_pending = TRUE
    /\ fiber_alive    = FALSE
    /\ phase          = "Offline"

\* ── Honest actions ─────────────────────────────────────────────

\* keeper_state_machine.ml's update_conditions Fiber_started arm.
\* Resets launch_pending and sets fiber_alive simultaneously.
\* derive_phase's `fiber_alive` branch (Running) fires once both
\* flags are updated.
FiberStart ==
    /\ launch_pending = TRUE
    /\ fiber_alive    = FALSE
    /\ launch_pending' = FALSE
    /\ fiber_alive'    = TRUE
    /\ phase'          = "Running"

\* keeper_registry.ml's mark_dead.  Resets both flags and lands
\* phase on Dead.  Modelled from any non-terminal state.
MarkDead ==
    /\ phase /= "Dead"
    /\ launch_pending' = FALSE
    /\ fiber_alive'    = FALSE
    /\ phase'          = "Dead"

\* Stutter so TLC does not flag deadlock once we reach Running or
\* Dead.  Both terminal-or-stable states from this spec's
\* projection.
Done ==
    /\ phase \in { "Running", "Dead" }
    /\ UNCHANGED vars

\* ── Bug action (only in SpecBuggy) ─────────────────────────────

\* The fiber starts but the launch_pending flag is forgotten.
\* Keeper would now report fiber_alive=TRUE *and* launch_pending=TRUE
\* — a drift the conditions json export
\* (`"launch_pending", \`Bool c.launch_pending` in keeper_state_machine.ml)
\* would surface as a confusing observability signal.  Critically,
\* derive_phase still routes to Running (its `fiber_alive` branch)
\* because the Offline branch demands ~fiber_alive — so the drift is
\* invisible to phase consumers but visible to anyone reading conditions.
FiberStartedWithoutClearing ==
    /\ launch_pending = TRUE
    /\ fiber_alive    = FALSE
    /\ launch_pending' = TRUE      \* drift: should be FALSE
    /\ fiber_alive'    = TRUE
    /\ phase'          = "Running"

\* ── Spec wirings ───────────────────────────────────────────────

Next      == FiberStart \/ MarkDead \/ Done
NextBuggy == Next \/ FiberStartedWithoutClearing

Spec      == Init /\ [][Next]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

\* ── Safety invariants ─────────────────────────────────────────

\* Sequential lifecycle: launch_pending and fiber_alive cannot both
\* be TRUE.  Mirrors derive_phase priority 2's exclusive condition
\* (launch_pending /\ ~fiber_alive => Offline).  Under SpecBuggy,
\* FiberStartedWithoutClearing violates this immediately.
LaunchPendingExclusive ==
    ~(launch_pending /\ fiber_alive)

\* Phase consistency: launch_pending implies Offline phase, and
\* Running implies launch_pending was cleared.  Captures the
\* observability invariant the spec exists to defend.
PhaseConsistent ==
    /\ (launch_pending => phase = "Offline")
    /\ (phase = "Running" => ~launch_pending)
    /\ (phase = "Dead"    => ~launch_pending /\ ~fiber_alive)

SafetyInvariant ==
    /\ TypeOK
    /\ LaunchPendingExclusive
    /\ PhaseConsistent

====
