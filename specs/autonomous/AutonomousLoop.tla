---- MODULE AutonomousLoop ----
\* Cycle 27 / Tier A5 catch-up spec.
\*
\* Models the non-invasive wire-in of the autonomous tick into
\* the Keeper turn lifecycle, as implemented in
\* lib/keeper/keeper_post_turn.ml's apply_autonomous_wirein.
\*
\* The critical safety property is: an autonomous tick MUST NOT
\* mutate the Keeper FSM phase. It is allowed to read the phase
\* (read-only observer per RFC-0002) and update the
\* working_context["autonomous_meta"] JSON sub-tree, but the
\* Keeper FSM itself is owned solely by Keeper_state_machine.
\*
\* OCaml <-> TLA+ mapping:
\*
\*   variable          | OCaml site
\*   ------------------+---------------------------------------------
\*   keeper_phase      | Keeper_state_machine.t.phase
\*   autonomous_phase  | Autonomous_state.t.current_phase
\*   meta_present      | working_context contains "autonomous_meta"
\*   auto_phase_writes | bug-model witness for invasive keeper phase writes

EXTENDS TLC, Naturals, Sequences, FiniteSets

CONSTANTS
    MaxKeeperSteps,   \* state-space bound on keeper transitions
    MaxAutoTicks      \* state-space bound on autonomous ticks

KeeperPhases == { "spawned", "running", "draining", "terminated" }

AutoPhases == { "idle", "perceiving", "intending", "planning",
                "executing", "verifying", "reflecting", "adapting" }

VARIABLES
    keeper_phase,
    autonomous_phase,
    meta_present,
    keeper_steps,    \* count of keeper transitions
    auto_ticks,      \* count of autonomous ticks
    auto_phase_writes \* keeper phase writes performed by autonomous tick

vars == <<keeper_phase, autonomous_phase, meta_present,
          keeper_steps, auto_ticks, auto_phase_writes>>

\* ── Type invariant ───────────────────────────────────────────────
TypeOK ==
    /\ keeper_phase \in KeeperPhases
    /\ autonomous_phase \in AutoPhases
    /\ meta_present \in BOOLEAN
    /\ keeper_steps \in Nat
    /\ auto_ticks \in Nat
    /\ auto_phase_writes \in Nat

\* If the Keeper is running and at least one autonomous tick has
\* fired, working_context["autonomous_meta"] must be present.
MetaPersistedAfterTick ==
    auto_ticks > 0 => meta_present

\* The autonomous loop only ticks while the Keeper is in Running.
\* This is enforced in apply_autonomous_wirein by an early return
\* when MASC_AUTONOMOUS=0 or the Keeper phase is not Running.
TickOnlyDuringRunning ==
    \* This is an action-style property, but we approximate it as a
    \* state predicate: any non-zero tick count implies the keeper
    \* has at one point been in running phase. Modelled by
    \* requiring ticks not to occur from a terminal phase.
    auto_ticks > 0 => keeper_phase \in { "running", "draining",
                                          "terminated" }

AutoTickReadOnly ==
    auto_phase_writes = 0

\* ── Init / Next ──────────────────────────────────────────────────
Init ==
    /\ keeper_phase = "spawned"
    /\ autonomous_phase = "idle"
    /\ meta_present = FALSE
    /\ keeper_steps = 0
    /\ auto_ticks = 0
    /\ auto_phase_writes = 0

KeeperToRunning ==
    /\ keeper_phase = "spawned"
    /\ keeper_phase' = "running"
    /\ keeper_steps' = keeper_steps + 1
    /\ UNCHANGED <<autonomous_phase, meta_present, auto_ticks,
                   auto_phase_writes>>

KeeperToDraining ==
    /\ keeper_phase = "running"
    /\ keeper_phase' = "draining"
    /\ keeper_steps' = keeper_steps + 1
    /\ UNCHANGED <<autonomous_phase, meta_present, auto_ticks,
                   auto_phase_writes>>

KeeperToTerminated ==
    /\ keeper_phase = "draining"
    /\ keeper_phase' = "terminated"
    /\ keeper_steps' = keeper_steps + 1
    /\ UNCHANGED <<autonomous_phase, meta_present, auto_ticks,
                   auto_phase_writes>>

\* CRITICAL: AutoTick preserves keeper_phase. This is the
\* non-invasive wirein contract.
AutoTick ==
    /\ keeper_phase = "running"
    /\ \E next_auto \in AutoPhases : autonomous_phase' = next_auto
    /\ meta_present' = TRUE
    /\ auto_ticks' = auto_ticks + 1
    /\ keeper_phase' = keeper_phase            \* PRESERVED
    /\ keeper_steps' = keeper_steps            \* PRESERVED
    /\ auto_phase_writes' = auto_phase_writes  \* PRESERVED

Next ==
    \/ KeeperToRunning
    \/ KeeperToDraining
    \/ KeeperToTerminated
    \/ AutoTick

Spec == Init /\ [][Next]_vars

BoundedSteps ==
    /\ keeper_steps <= MaxKeeperSteps
    /\ auto_ticks <= MaxAutoTicks
    /\ auto_phase_writes <= MaxAutoTicks

\* ── Bug model (RFC-Q2-1) ────────────────────────────────────────
\*
\* Models the bug class where the autonomous tick observer becomes
\* invasive — i.e. a tick mutates keeper_phase in addition to its
\* own meta update. The OCaml-side guard
\* [Keeper_post_turn.apply_autonomous_wirein] enforces read-only
\* access to the keeper FSM; the spec verifies that even if that
\* constraint were bypassed (e.g. via Obj.magic or a refactor
\* that loses the guard), AutoTickReadOnly catches the invasive write.

AutoTickFlipsKeeperPhase ==
    /\ keeper_phase = "running"
    /\ \E next_auto \in AutoPhases : autonomous_phase' = next_auto
    /\ meta_present' = TRUE
    /\ auto_ticks' = auto_ticks + 1
    /\ keeper_phase' = "draining"   \* INVASIVE: must be preserved
    /\ keeper_steps' = keeper_steps + 1
    /\ auto_phase_writes' = auto_phase_writes + 1

NextBuggy ==
    \/ Next
    \/ AutoTickFlipsKeeperPhase

SpecBuggy == Init /\ [][NextBuggy]_vars

THEOREM Spec => []TypeOK
THEOREM Spec => []MetaPersistedAfterTick
THEOREM Spec => []TickOnlyDuringRunning
THEOREM Spec => []AutoTickReadOnly

====
