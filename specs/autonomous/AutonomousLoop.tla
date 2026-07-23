---- MODULE AutonomousLoop ----
\* Non-invasive autonomous tick projection.
\*
\* An autonomous tick may update only its own typed state and metadata. It must
\* not mutate Keeper lifecycle authority. Failing, Overflowed, Compacting, and
\* HandingOff remain work-capable alongside Running.

EXTENDS TLC, Naturals

CONSTANTS
    MaxKeeperSteps,
    MaxAutoTicks

KeeperPhases == {
    "Offline", "Running", "Failing", "Overflowed", "Compacting",
    "HandingOff", "Draining", "Paused", "Stopped", "Crashed",
    "Restarting", "Dead"
}

WorkCapable == {
    "Running", "Failing", "Overflowed", "Compacting", "HandingOff"
}

AutoPhases == {
    "idle", "perceiving", "intending", "planning", "executing",
    "verifying", "reflecting", "adapting"
}

VARIABLES
    keeper_phase,
    autonomous_phase,
    meta_present,
    keeper_steps,
    auto_ticks,
    auto_phase_writes

vars == << keeper_phase, autonomous_phase, meta_present,
           keeper_steps, auto_ticks, auto_phase_writes >>

TypeOK ==
    /\ keeper_phase \in KeeperPhases
    /\ autonomous_phase \in AutoPhases
    /\ meta_present \in BOOLEAN
    /\ keeper_steps \in Nat
    /\ auto_ticks \in Nat
    /\ auto_phase_writes \in Nat

Init ==
    /\ keeper_phase = "Running"
    /\ autonomous_phase = "idle"
    /\ meta_present = FALSE
    /\ keeper_steps = 0
    /\ auto_ticks = 0
    /\ auto_phase_writes = 0

\* Lifecycle changes are external inputs to this observer.
ObserveKeeperPhase(next_phase) ==
    /\ next_phase \in KeeperPhases
    /\ keeper_phase' = next_phase
    /\ keeper_steps' = keeper_steps + 1
    /\ UNCHANGED << autonomous_phase, meta_present, auto_ticks,
                    auto_phase_writes >>

AutoTick ==
    /\ keeper_phase \in WorkCapable
    /\ \E next_auto \in AutoPhases : autonomous_phase' = next_auto
    /\ meta_present' = TRUE
    /\ auto_ticks' = auto_ticks + 1
    /\ UNCHANGED << keeper_phase, keeper_steps, auto_phase_writes >>

Next ==
    \/ \E next_phase \in KeeperPhases : ObserveKeeperPhase(next_phase)
    \/ AutoTick

Spec == Init /\ [][Next]_vars

BoundedSteps ==
    /\ keeper_steps <= MaxKeeperSteps
    /\ auto_ticks <= MaxAutoTicks
    /\ auto_phase_writes <= MaxAutoTicks

MetaPersistedAfterTick == auto_ticks > 0 => meta_present
AutoTickReadOnly == auto_phase_writes = 0

\* Bug witness: the observer writes a Keeper lifecycle phase.
AutoTickFlipsKeeperPhase ==
    /\ keeper_phase \in WorkCapable
    /\ keeper_phase' = "Paused"
    /\ \E next_auto \in AutoPhases : autonomous_phase' = next_auto
    /\ meta_present' = TRUE
    /\ auto_ticks' = auto_ticks + 1
    /\ auto_phase_writes' = auto_phase_writes + 1
    /\ UNCHANGED keeper_steps

NextBuggy == Next \/ AutoTickFlipsKeeperPhase
SpecBuggy == Init /\ [][NextBuggy]_vars

====
