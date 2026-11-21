---- MODULE KeeperReactionQueue ----
\* One Keeper's durable input queue under RFC-keeper-reaction-and-queue.
\* An input's kind decides only when it raises the Keeper's wake. Whatever
\* opens a turn, the turn takes every input that is waiting, raised or not.
\*
\*   human   operator chat, HITL answer, Ask answer. Raised at enqueue.
\*   keeper  a React input another Keeper made. Raised at the next tick
\*           boundary of this Keeper's fixed phase, together with every other
\*           keeper input that waited through that boundary.
\*   carry   never raised. It rides the next turn, at the latest the turn of
\*           the next periodic boundary.
\*
\* Time counts tick boundaries. A turn spans at most TurnBound boundaries: a
\* turn closes at the typed end the model reports, and the bound stands for
\* that end. A Keeper whose wake is raised or whose periodic boundary is due
\* starts its cycle before the next boundary. The fixed phase that keeps
\* Keepers off the same instant is not visible in one Keeper's model.
\*
\* Runtime correspondence the RFC steps write:
\*   - Keeper_keepalive_signal.wakeup_keeper raises the wake for human input
\*     at enqueue. The tick boundary raises it for keeper input. Carry input
\*     is enqueued without it.
\*   - The keepalive verdict opens a turn only for a raised input or a due
\*     clock (CycleStart). The turn's claim takes every waiting entry across
\*     senders (steps 2-3 of
\*     RFC-a-keeper-takes-every-waiting-message-in-one-turn).
\*   - pending_stimulus_remains, read by next_cycle_starts_now, counts only
\*     raised entries.
\*   - periodic_cadence_after_cycle consumes the periodic boundary when the
\*     cycle that served it ends (TurnEnd).
\*
\* Planted bugs, one buggy cfg each:
\*   MissedDirectedWake     the wake is consumed but no cycle starts.
\*   HumanWaitsForBoundary  human input is enqueued without its wake.
\*   ClaimOneSender         a turn takes only the oldest input's sender; the
\*                          next sender waits for the next turn.
\*   OneTurnPerTick         ClaimOneSender, and the inputs left behind lose
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
    Senders

ASSUME ConstantsOK ==
    /\ MaxStimuli \in Nat /\ MaxStimuli >= 2
    /\ MaxTime \in Nat
    /\ Period \in Nat \ {0}
    /\ TurnBound \in Nat \ {0}
    /\ LastArrival \in Nat /\ LastArrival < MaxTime
    /\ Senders # {}

Kinds == {"human", "keeper", "carry"}

Entries ==
    [ id : 1..MaxStimuli, kind : Kinds, sender : Senders,
      arrived : 0..MaxTime, raised : BOOLEAN ]

Max(a, b) == IF a >= b THEN a ELSE b

\* The longest a human input waits: the turn that was running when it came.
HumanDelay == TurnBound

\* The longest a keeper input waits: one boundary, or the turn that was
\* running when it came.
KeeperDelay == Max(1, TurnBound)

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

Entry(kind, sender) ==
    [ id |-> enqueued_total + 1, kind |-> kind, sender |-> sender,
      arrived |-> now, raised |-> kind = "human" ]

Enqueue ==
    /\ enqueued_total < MaxStimuli
    /\ now <= LastArrival
    /\ \E kind \in Kinds, sender \in Senders :
         /\ waiting' = waiting \cup { Entry(kind, sender) }
         /\ wake' = (wake \/ kind = "human")
    /\ enqueued_total' = enqueued_total + 1
    /\ UNCHANGED << now, claimed_total, cycle, turn_started, turn_periodic,
                    turn_cause, last_periodic >>

\* The next tick boundary. A Keeper whose wake is raised or whose periodic
\* boundary is due has started its cycle before it, and a running turn ends
\* within TurnBound boundaries. Every keeper input that waited through the
\* boundary is raised at once, whatever its count.
Boundary ==
    /\ now < MaxTime
    /\ ~(cycle = "sleeping" /\ (wake \/ PeriodicDue))
    /\ ~(cycle = "running" /\ now - turn_started >= TurnBound)
    /\ now' = now + 1
    /\ waiting' =
         { [ e EXCEPT !.raised = (e.raised \/ e.kind = "keeper") ] : e \in waiting }
    /\ wake' = (wake \/ \E e \in waiting : e.kind = "keeper" /\ ~e.raised)
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

HumanWaitsForBoundary ==
    /\ enqueued_total < MaxStimuli
    /\ now <= LastArrival
    /\ \E sender \in Senders :
         waiting' = waiting \cup
           { [ Entry("human", sender) EXCEPT !.raised = FALSE ] }
    /\ enqueued_total' = enqueued_total + 1
    /\ UNCHANGED << now, claimed_total, wake, cycle, turn_started,
                    turn_periodic, turn_cause, last_periodic >>

Oldest == CHOOSE e \in waiting : \A f \in waiting : e.id <= f.id

Taken == { e \in waiting : e.sender = Oldest.sender }

StartTakingOneSender(keep_wake) ==
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

ClaimOneSender == StartTakingOneSender(TRUE)

OneTurnPerTick == StartTakingOneSender(FALSE)

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
SpecHumanWaitsForBoundary   == Init /\ [][Next \/ HumanWaitsForBoundary]_vars
SpecClaimOneSender          == Init /\ [][Next \/ ClaimOneSender]_vars
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

\* Human input never waits for a boundary: a wake or a running turn owns it.
HumanRoutable ==
    \A e \in waiting : e.kind = "human" => (wake \/ cycle = "running")

\* An input whose wake was raised is owned by a wake or a running turn.
RaisedRoutable ==
    \A e \in waiting : e.raised => (wake \/ cycle = "running")

HumanAgeBound ==
    \A e \in waiting : e.kind = "human" => now - e.arrived <= HumanDelay

\* Whatever the count of inputs or senders, a keeper input waits one
\* boundary or one running turn.
KeeperAgeBound ==
    \A e \in waiting : e.kind = "keeper" => now - e.arrived <= KeeperDelay

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
    /\ HumanRoutable
    /\ RaisedRoutable
    /\ HumanAgeBound
    /\ KeeperAgeBound
    /\ CarryAgeBound
    /\ TurnHasCause

====
