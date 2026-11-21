---- MODULE KeeperReactionQueue ----
\* One Keeper's durable input queue under RFC-keeper-reaction-and-queue.
\* An input's kind decides only when it raises the Keeper's wake. Whatever
\* opens a turn, the turn takes every input that is waiting, raised or not.
\*
\*   now      raised at enqueue.
\*   at_tick  raised at the next tick boundary of this Keeper's fixed phase,
\*            together with every other at_tick input that waited through
\*            that boundary.
\*   carry    never raised. It rides the next turn, at the latest the turn of
\*            the next periodic boundary.
\*
\* The producer of an input picks its kind. The RFC's input table (section
\* 4.1) lists which payload takes which kind.
\*
\* Time counts tick boundaries. A turn spans at most TurnBound boundaries: a
\* turn closes at the typed end the model reports, and the bound stands for
\* that end. A Keeper whose wake is raised or whose periodic boundary is due
\* starts its cycle before the next boundary. The fixed phase that keeps
\* Keepers off the same instant is not visible in one Keeper's model.
\*
\* Runtime correspondence the RFC steps write:
\*   - Keeper_keepalive_signal.wakeup_keeper raises the wake for now input
\*     at enqueue. The tick boundary raises it for at_tick input. Carry input
\*     is enqueued without it.
\*   - The keepalive verdict opens a turn only for a raised input or a due
\*     clock (CycleStart). The turn's claim takes every waiting entry across
\*     sources (steps 2-3 of
\*     RFC-a-keeper-takes-every-waiting-message-in-one-turn). A source is the
\*     key today's select groups a batch by (that RFC, section 2.2).
\*   - pending_stimulus_remains, read by next_cycle_starts_now, counts only
\*     raised entries.
\*   - periodic_cadence_after_cycle consumes the periodic boundary when the
\*     cycle that served it ends (TurnEnd).
\*
\* Planted bugs, one buggy cfg each:
\*   MissedDirectedWake     the wake is consumed but no cycle starts.
\*   NowWaitsForBoundary    now input is enqueued without its wake.
\*   ClaimOneSource         a turn takes only the oldest input's source; the
\*                          next source waits for the next turn.
\*   OneTurnPerTick         ClaimOneSource, and the inputs left behind lose
\*                          their wake until the next boundary.
\*   PeriodicSkipsCarry     a due periodic cycle opens no turn while only
\*                          carry input waits, and consumes the boundary.
\*   TurnForUnraisedInput   a cycle opens a turn for input nothing raised.

EXTENDS Naturals, FiniteSets

CONSTANTS
    MaxStimuli,  \* finite TLC environment, not a runtime queue limit
    MaxTime,     \* the last tick boundary TLC explores
    Period,      \* periodic interval, in tick boundaries
    TurnBound,   \* longest turn, in tick boundaries
    LastArrival, \* the last tick boundary an input may arrive at
    Sources

ASSUME ConstantsOK ==
    /\ MaxStimuli \in Nat /\ MaxStimuli >= 2
    /\ MaxTime \in Nat
    /\ Period \in Nat \ {0}
    /\ TurnBound \in Nat \ {0}
    /\ LastArrival \in Nat /\ LastArrival < MaxTime
    /\ Sources # {}

Kinds == {"now", "at_tick", "carry"}

Entries ==
    [ id : 1..MaxStimuli, kind : Kinds, source : Sources,
      arrived : 0..MaxTime, raised : BOOLEAN ]

Max(a, b) == IF a >= b THEN a ELSE b

\* The longest a now input waits: the turn that was running when it came.
NowDelay == TurnBound

\* The longest an at_tick input waits: one boundary, or the turn that was
\* running when it came.
AtTickDelay == Max(1, TurnBound)

\* The longest a carry input waits: one periodic interval, counted from the
\* end of the turn that served the last periodic boundary.
CarryDelay == Period + TurnBound

VARIABLES
    now,
    waiting,
    enqueued_total,
    claimed_total,
    wake,
    cycle,
    turn_started,
    turn_periodic,
    turn_cause,
    last_periodic

vars ==
    << now, waiting, enqueued_total, claimed_total, wake, cycle,
       turn_started, turn_periodic, turn_cause, last_periodic >>

TypeOK ==
    /\ now \in 0..MaxTime
    /\ waiting \subseteq Entries
    /\ enqueued_total \in 0..MaxStimuli
    /\ claimed_total \in 0..MaxStimuli
    /\ wake \in BOOLEAN
    /\ cycle \in {"sleeping", "running"}
    /\ turn_started \in 0..MaxTime
    /\ turn_periodic \in BOOLEAN
    /\ turn_cause \in {"idle", "raised", "periodic", "none"}
    /\ last_periodic \in 0..MaxTime

Init ==
    /\ now = 0
    /\ waiting = {}
    /\ enqueued_total = 0
    /\ claimed_total = 0
    /\ wake = FALSE
    /\ cycle = "sleeping"
    /\ turn_started = 0
    /\ turn_periodic = FALSE
    /\ turn_cause = "idle"
    /\ last_periodic = 0

PeriodicDue == now - last_periodic >= Period

Entry(kind, source) ==
    [ id |-> enqueued_total + 1, kind |-> kind, source |-> source,
      arrived |-> now, raised |-> kind = "now" ]

Enqueue ==
    /\ enqueued_total < MaxStimuli
    /\ now <= LastArrival
    /\ \E kind \in Kinds, source \in Sources :
         /\ waiting' = waiting \cup { Entry(kind, source) }
         /\ wake' = (wake \/ kind = "now")
    /\ enqueued_total' = enqueued_total + 1
    /\ UNCHANGED << now, claimed_total, cycle, turn_started, turn_periodic,
                    turn_cause, last_periodic >>

\* The next tick boundary. A Keeper whose wake is raised or whose periodic
\* boundary is due has started its cycle before it, and a running turn ends
\* within TurnBound boundaries. Every at_tick input that waited through the
\* boundary is raised at once, whatever its count.
Boundary ==
    /\ now < MaxTime
    /\ ~(cycle = "sleeping" /\ (wake \/ PeriodicDue))
    /\ ~(cycle = "running" /\ now - turn_started >= TurnBound)
    /\ now' = now + 1
    /\ waiting' =
         { [ e EXCEPT !.raised = (e.raised \/ e.kind = "at_tick") ] : e \in waiting }
    /\ wake' = (wake \/ \E e \in waiting : e.kind = "at_tick" /\ ~e.raised)
    /\ UNCHANGED << enqueued_total, claimed_total, cycle, turn_started,
                    turn_periodic, turn_cause, last_periodic >>

TurnCause ==
    IF \E e \in waiting : e.raised THEN "raised"
    ELSE IF PeriodicDue THEN "periodic"
    ELSE "none"

\* The Keeper consumes its wake or its due periodic boundary. It opens a turn
\* when an input raised the wake or the periodic boundary is due, and the
\* turn takes every waiting input. A wake whose input an earlier turn already
\* took opens no turn.
CycleStart ==
    /\ cycle = "sleeping"
    /\ wake \/ PeriodicDue
    /\ wake' = FALSE
    /\ IF TurnCause = "none"
         THEN UNCHANGED << waiting, claimed_total, cycle, turn_started,
                           turn_periodic, turn_cause >>
         ELSE /\ cycle' = "running"
              /\ turn_started' = now
              /\ turn_periodic' = PeriodicDue
              /\ turn_cause' = TurnCause
              /\ claimed_total' = claimed_total + Cardinality(waiting)
              /\ waiting' = {}
    /\ UNCHANGED << now, enqueued_total, last_periodic >>

\* The runtime consumes the wake before the turn claims, so the wake of an
\* input the running turn takes can land after the claim.
LateWake ==
    /\ cycle = "running"
    /\ ~wake
    /\ wake' = TRUE
    /\ UNCHANGED << now, waiting, enqueued_total, claimed_total, cycle,
                    turn_started, turn_periodic, turn_cause, last_periodic >>

TurnEnd ==
    /\ cycle = "running"
    /\ cycle' = "sleeping"
    /\ last_periodic' = IF turn_periodic THEN now ELSE last_periodic
    /\ UNCHANGED << now, waiting, enqueued_total, claimed_total, wake,
                    turn_started, turn_periodic, turn_cause >>

\* TLC explores a finite clock. After the last boundary, stuttering is all
\* that is left.
Horizon ==
    /\ now = MaxTime
    /\ UNCHANGED vars

Next ==
    \/ Enqueue
    \/ Boundary
    \/ CycleStart
    \/ LateWake
    \/ TurnEnd
    \/ Horizon

\* ── Planted bugs ──────────────────────────────────────────────

MissedDirectedWake ==
    /\ cycle = "sleeping"
    /\ wake
    /\ \E e \in waiting : e.raised
    /\ wake' = FALSE
    /\ UNCHANGED << now, waiting, enqueued_total, claimed_total, cycle,
                    turn_started, turn_periodic, turn_cause, last_periodic >>

NowWaitsForBoundary ==
    /\ enqueued_total < MaxStimuli
    /\ now <= LastArrival
    /\ \E source \in Sources :
         waiting' = waiting \cup
           { [ Entry("now", source) EXCEPT !.raised = FALSE ] }
    /\ enqueued_total' = enqueued_total + 1
    /\ UNCHANGED << now, claimed_total, wake, cycle, turn_started,
                    turn_periodic, turn_cause, last_periodic >>

Oldest == CHOOSE e \in waiting : \A f \in waiting : e.id <= f.id

Taken == { e \in waiting : e.source = Oldest.source }

StartTakingOneSource(keep_wake) ==
    /\ cycle = "sleeping"
    /\ wake \/ PeriodicDue
    /\ TurnCause # "none"
    /\ waiting # {}
    /\ cycle' = "running"
    /\ turn_started' = now
    /\ turn_periodic' = PeriodicDue
    /\ turn_cause' = TurnCause
    /\ claimed_total' = claimed_total + Cardinality(Taken)
    /\ waiting' = waiting \ Taken
    /\ wake' = (keep_wake /\ \E e \in waiting \ Taken : e.raised)
    /\ UNCHANGED << now, enqueued_total, last_periodic >>

ClaimOneSource == StartTakingOneSource(TRUE)

OneTurnPerTick == StartTakingOneSource(FALSE)

PeriodicSkipsCarry ==
    /\ cycle = "sleeping"
    /\ TurnCause = "periodic"
    /\ \E e \in waiting : e.kind = "carry"
    /\ wake' = FALSE
    /\ last_periodic' = now
    /\ UNCHANGED << now, waiting, enqueued_total, claimed_total, cycle,
                    turn_started, turn_periodic, turn_cause >>

TurnForUnraisedInput ==
    /\ cycle = "sleeping"
    /\ wake
    /\ TurnCause = "none"
    /\ waiting # {}
    /\ wake' = FALSE
    /\ cycle' = "running"
    /\ turn_started' = now
    /\ turn_periodic' = FALSE
    /\ turn_cause' = "none"
    /\ claimed_total' = claimed_total + Cardinality(waiting)
    /\ waiting' = {}
    /\ UNCHANGED << now, enqueued_total, last_periodic >>

Spec                        == Init /\ [][Next]_vars
SpecMissedDirectedWake      == Init /\ [][Next \/ MissedDirectedWake]_vars
SpecNowWaitsForBoundary   == Init /\ [][Next \/ NowWaitsForBoundary]_vars
SpecClaimOneSource          == Init /\ [][Next \/ ClaimOneSource]_vars
SpecOneTurnPerTick          == Init /\ [][Next \/ OneTurnPerTick]_vars
SpecPeriodicSkipsCarry      == Init /\ [][Next \/ PeriodicSkipsCarry]_vars
SpecTurnForUnraisedInput    == Init /\ [][Next \/ TurnForUnraisedInput]_vars

\* A woken Keeper starts its cycle, a running turn ends, and the clock keeps
\* moving while it can.
Fairness ==
    /\ WF_vars(Boundary)
    /\ WF_vars(CycleStart)
    /\ WF_vars(TurnEnd)

FairSpec                    == Spec /\ Fairness
FairSpecPeriodicSkipsCarry  == SpecPeriodicSkipsCarry /\ Fairness

\* ── Invariants ────────────────────────────────────────────────

Conservation == claimed_total + Cardinality(waiting) = enqueued_total

\* Now input never waits for a boundary: a wake or a running turn owns it.
NowRoutable ==
    \A e \in waiting : e.kind = "now" => (wake \/ cycle = "running")

\* An input whose wake was raised is owned by a wake or a running turn.
RaisedRoutable ==
    \A e \in waiting : e.raised => (wake \/ cycle = "running")

NowAgeBound ==
    \A e \in waiting : e.kind = "now" => now - e.arrived <= NowDelay

\* Whatever the count of inputs or sources, an at_tick input waits one
\* boundary or one running turn.
AtTickAgeBound ==
    \A e \in waiting : e.kind = "at_tick" => now - e.arrived <= AtTickDelay

CarryAgeBound ==
    \A e \in waiting : e.kind = "carry" => now - e.arrived <= CarryDelay

\* A turn opens only for a raised input or a due periodic boundary.
TurnHasCause ==
    cycle = "running" => turn_cause \in {"raised", "periodic"}

\* Every waiting input reaches a turn. The fair cfgs keep arrivals early
\* enough that each one's longest wait ends before the last boundary.
EveryInputReachesATurn == (waiting # {}) ~> (waiting = {})

SafetyInvariant ==
    /\ Conservation
    /\ NowRoutable
    /\ RaisedRoutable
    /\ NowAgeBound
    /\ AtTickAgeBound
    /\ CarryAgeBound
    /\ TurnHasCause

====
