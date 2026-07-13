---- MODULE KeeperEventQueue ----
\* Durable per-Keeper stimulus queue and directed wake contract.
\*
\* Runtime correspondence:
\*   - Keeper_registry_event_queue persists queue entries.
\*   - Keeper_keepalive_signal.wakeup_keeper enqueues the payload before
\*     setting the target Keeper's fiber_wakeup atomic.
\*   - Keeper_keepalive_signal.interruptible_sleep consumes that atomic with
\*     Atomic.compare_and_set true false.
\*   - Keeper_heartbeat_loop runs every configured heartbeat tick and never
\*     suppresses a cycle based on busy/idle/activity/observer heuristics.
\*
\* The clean model proves that queued work is always either backed by a wake
\* hint or already inside the Keeper cycle. The buggy action clears a directed
\* wake without starting a cycle, making the durable work unroutable.

EXTENDS Naturals

CONSTANT MaxStimuli  \* finite TLC environment, not a runtime queue limit

ASSUME MaxStimuliOK   == MaxStimuli   \in Nat /\ MaxStimuli   >= 2

VARIABLES
    queue_size,
    enqueued_total,
    dequeued_total,
    wakeup_signaled,
    cycle_state

vars ==
    << queue_size,
       enqueued_total,
       dequeued_total,
       wakeup_signaled,
       cycle_state >>

TypeOK ==
    /\ queue_size      \in 0..MaxStimuli
    /\ enqueued_total  \in 0..MaxStimuli
    /\ dequeued_total  \in 0..MaxStimuli
    /\ wakeup_signaled \in BOOLEAN
    /\ cycle_state     \in {"sleeping", "running"}

Init ==
    /\ queue_size      = 0
    /\ enqueued_total  = 0
    /\ dequeued_total  = 0
    /\ wakeup_signaled = FALSE
    /\ cycle_state     = "sleeping"

\* A durable stimulus and its directed wake hint are published together.
Enqueue ==
    /\ enqueued_total < MaxStimuli
    /\ queue_size'      = queue_size + 1
    /\ enqueued_total'  = enqueued_total + 1
    /\ wakeup_signaled' = TRUE
    /\ UNCHANGED << dequeued_total, cycle_state >>

\* The target Keeper consumes its wake and enters the cycle immediately.
DirectedWakeCycle ==
    /\ cycle_state = "sleeping"
    /\ wakeup_signaled = TRUE
    /\ wakeup_signaled' = FALSE
    /\ cycle_state' = "running"
    /\ UNCHANGED << queue_size, enqueued_total, dequeued_total >>

\* With no directed wake, the configured heartbeat cadence still opens a
\* cycle. There is no adaptive skip decision in this state machine.
ConfiguredCadenceCycle ==
    /\ cycle_state = "sleeping"
    /\ wakeup_signaled = FALSE
    /\ cycle_state' = "running"
    /\ UNCHANGED << queue_size, enqueued_total, dequeued_total,
                    wakeup_signaled >>

\* Consume exactly one durable stimulus. If more remain, preserve a wake hint
\* so the lane cannot park with an unroutable queue.
TurnDequeue ==
    /\ cycle_state = "running"
    /\ queue_size > 0
    /\ queue_size' = queue_size - 1
    /\ dequeued_total' = dequeued_total + 1
    /\ wakeup_signaled' = (wakeup_signaled \/ queue_size > 1)
    /\ cycle_state' = "sleeping"
    /\ UNCHANGED enqueued_total

\* A cadence cycle with no stimulus returns to the configured sleep.
TurnWithoutStimulus ==
    /\ cycle_state = "running"
    /\ queue_size = 0
    /\ cycle_state' = "sleeping"
    /\ UNCHANGED << queue_size, enqueued_total, dequeued_total,
                    wakeup_signaled >>

Done ==
    /\ enqueued_total = MaxStimuli
    /\ queue_size = 0
    /\ cycle_state = "sleeping"
    /\ wakeup_signaled = FALSE
    /\ UNCHANGED vars

\* Bug model: the atomic is consumed but the target Keeper cycle does not
\* start. Durable work remains, yet neither a wake nor an active cycle owns it.
MissedDirectedWake ==
    /\ cycle_state = "sleeping"
    /\ wakeup_signaled = TRUE
    /\ queue_size > 0
    /\ wakeup_signaled' = FALSE
    /\ UNCHANGED << queue_size, enqueued_total, dequeued_total, cycle_state >>

Next ==
    \/ Enqueue
    \/ DirectedWakeCycle
    \/ ConfiguredCadenceCycle
    \/ TurnDequeue
    \/ TurnWithoutStimulus
    \/ Done

NextBuggy == Next \/ MissedDirectedWake

Spec      == Init /\ [][Next]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

Conservation == enqueued_total >= dequeued_total

QueueDepthMatchesLedger ==
    queue_size = enqueued_total - dequeued_total

QueuedWorkRoutable ==
    (queue_size > 0) => (wakeup_signaled \/ cycle_state = "running")

SafetyInvariant ==
    /\ Conservation
    /\ QueueDepthMatchesLedger
    /\ QueuedWorkRoutable

====
