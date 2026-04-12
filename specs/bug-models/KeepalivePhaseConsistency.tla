---- MODULE KeepalivePhaseConsistency ----
\* Bug Model: Keepalive fiber must not dispatch turns while the keeper
\* is in a non-dispatchable phase (Dead/Stopped/Compacting/HandingOff).
\*
\* Background (blog: Anthropic "Multi-Agent Coordination Patterns",
\* Shared State pattern): A keepalive fiber running alongside the
\* FSM can react to a stale phase snapshot and dispatch a turn
\* after the phase has transitioned to a terminal/suspended state.
\* This is the reactive-loop risk the blog warns about.
\*
\* masc-mcp reference: lib/keeper/keeper_keepalive.ml (~1819 lines)
\* dispatches turns via OAS. The keeper_state_machine.ml phase is
\* observed, but without explicit gating on every dispatch site, a
\* ghost dispatch under Compacting/HandingOff becomes possible.
\*
\* Invariant: a turn must never be in flight while the phase is one
\* of the non-dispatchable states.
\*
\* ── Abstraction note ──
\* The real keeper_state_machine.ml has 11 phases:
\*   Offline, Running, Failing, Compacting, HandingOff, Draining,
\*   Paused, Stopped, Crashed, Restarting, Dead.
\* This model collapses them to 6 representative phases for the
\* keepalive-dispatch invariant. The collapse:
\*   - Failing/Crashed/Restarting -> not modeled (treated as Offline or
\*     Running by the dispatcher; their invariants belong to
\*     KeeperStateMachine.tla, not this spec).
\*   - Draining -> not modeled (a variant of Stopped for the keepalive
\*     contract; no dispatch allowed in either).
\*   - Paused -> not modeled here. Paused is a caller-controlled soft
\*     pause in the real FSM; whether it is dispatchable is out of
\*     scope for this bug model. Intentionally omitted so the model
\*     does not accidentally constrain paused semantics.
\* The 6 modeled phases cover every transition relevant to the
\* "ghost dispatch under non-dispatchable phase" bug. Any future
\* change that adds a new non-dispatchable phase requires extending
\* [NonDispatchable] below.

VARIABLES
    phase,           \* "offline" | "running" | "compacting"
                     \* | "handing_off" | "stopped" | "dead"
    turn_in_flight   \* Boolean: keepalive has dispatched a turn, awaiting reply

vars == <<phase, turn_in_flight>>

Phases == {"offline", "running", "compacting", "handing_off",
           "stopped", "dead"}

NonDispatchable == {"offline", "compacting", "handing_off", "stopped", "dead"}

TypeOK ==
    /\ phase \in Phases
    /\ turn_in_flight \in {TRUE, FALSE}

Init ==
    /\ phase = "offline"
    /\ turn_in_flight = FALSE

\* ── Normal transitions ────────────────────────────────

Register ==
    /\ phase = "offline"
    /\ turn_in_flight = FALSE
    /\ phase' = "running"
    /\ UNCHANGED turn_in_flight

\* Clean dispatch: only allowed when phase="running".
DispatchTurn ==
    /\ phase = "running"
    /\ turn_in_flight = FALSE
    /\ turn_in_flight' = TRUE
    /\ UNCHANGED phase

TurnCompleted ==
    /\ turn_in_flight = TRUE
    /\ turn_in_flight' = FALSE
    /\ UNCHANGED phase

\* Compaction/handoff/stop must drain turn_in_flight first before
\* transitioning — the clean path requires a drain.
StartCompaction ==
    /\ phase = "running"
    /\ turn_in_flight = FALSE
    /\ phase' = "compacting"
    /\ UNCHANGED turn_in_flight

FinishCompaction ==
    /\ phase = "compacting"
    /\ phase' = "running"
    /\ UNCHANGED turn_in_flight

StartHandoff ==
    /\ phase = "running"
    /\ turn_in_flight = FALSE
    /\ phase' = "handing_off"
    /\ UNCHANGED turn_in_flight

FinishHandoff ==
    /\ phase = "handing_off"
    /\ phase' = "stopped"
    /\ UNCHANGED turn_in_flight

MarkDead ==
    /\ phase \in {"running", "handing_off", "stopped"}
    /\ turn_in_flight = FALSE
    /\ phase' = "dead"
    /\ UNCHANGED turn_in_flight

\* ── Clean Next ────────────────────────────────────────

Next ==
    \/ Register
    \/ DispatchTurn
    \/ TurnCompleted
    \/ StartCompaction
    \/ FinishCompaction
    \/ StartHandoff
    \/ FinishHandoff
    \/ MarkDead

Spec == Init /\ [][Next]_vars

\* ── Safety Invariants ─────────────────────────────────

\* Core invariant: if the keeper is in a non-dispatchable phase,
\* there must be no turn in flight.
KeepalivePhaseConsistent ==
    (phase \in NonDispatchable) => (turn_in_flight = FALSE)

\* A turn that is in flight implies the phase is a dispatch-capable
\* state.
InFlightImpliesRunning ==
    turn_in_flight = TRUE => phase = "running"

\* ── Bug Model: ghost dispatch ─────────────────────────
\* Bug: keepalive dispatches a turn based on a stale phase snapshot
\* — specifically, the fiber reads phase="running", then the FSM
\* transitions to compacting/handing_off between the read and the
\* dispatch. Model this as a single action that dispatches from a
\* non-dispatchable phase.

GhostDispatch ==
    /\ phase \in {"compacting", "handing_off"}
    /\ turn_in_flight = FALSE
    /\ turn_in_flight' = TRUE
    /\ UNCHANGED phase

\* Also model the reverse race: transition away from running while a
\* turn is already in flight (no drain).
NoDrainTransition ==
    /\ phase = "running"
    /\ turn_in_flight = TRUE
    /\ phase' = "compacting"
    /\ UNCHANGED turn_in_flight

NextBuggy ==
    \/ Next
    \/ GhostDispatch
    \/ NoDrainTransition

SpecBuggy == Init /\ [][NextBuggy]_vars

====
