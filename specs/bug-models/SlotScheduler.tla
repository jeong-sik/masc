---- MODULE SlotScheduler ----
\* Bug Model: Single-slot FIFO scheduler starvation.
\*
\* Models MASC_KEEPER_AUTONOMOUS_CONCURRENCY=3 with 1 LLM slot.
\* 3 keepers enqueue requests; 1 slot processes them FIFO.
\* Bug: if slot release is omitted (e.g. timeout without cleanup),
\* the slot is permanently occupied and all keepers starve.

EXTENDS Naturals, Sequences

CONSTANTS NumKeepers  \* Number of concurrent keepers (e.g. 3)

VARIABLES
    queue,          \* Sequence of keeper IDs waiting
    active,         \* 0 = slot free, 1..NumKeepers = keeper using slot
    completed,      \* Set of keepers that finished at least once
    slot_stuck      \* Boolean: slot permanently occupied (bug state)

vars == <<queue, active, completed, slot_stuck>>

Keepers == 1..NumKeepers

TypeOK ==
    /\ active \in 0..NumKeepers
    /\ slot_stuck \in {TRUE, FALSE}

Init ==
    /\ queue = <<>>
    /\ active = 0
    /\ completed = {}
    /\ slot_stuck = FALSE

\* Keeper enqueues a request
Enqueue(k) ==
    /\ \A i \in 1..Len(queue) : queue[i] # k  \* Not already queued
    /\ k # active                               \* Not already active
    /\ queue' = Append(queue, k)
    /\ UNCHANGED <<active, completed, slot_stuck>>

\* Slot becomes available, dequeue next
Dequeue ==
    /\ active = 0
    /\ Len(queue) > 0
    /\ active' = Head(queue)
    /\ queue' = Tail(queue)
    /\ UNCHANGED <<completed, slot_stuck>>

\* Active keeper finishes and releases slot
SlotRelease ==
    /\ active # 0
    /\ ~slot_stuck
    /\ completed' = completed \union {active}
    /\ active' = 0
    /\ UNCHANGED <<queue, slot_stuck>>

\* ── Clean Next ─────────────────────────────────────────

Next ==
    \/ \E k \in Keepers : Enqueue(k)
    \/ Dequeue
    \/ SlotRelease

Spec == Init /\ [][Next]_vars /\ WF_vars(Dequeue) /\ WF_vars(SlotRelease)

\* ── Safety ─────────────────────────────────────────────

\* At most 1 keeper active at any time.
MutualExclusion ==
    active \in 0..NumKeepers

\* ── Liveness ───────────────────────────────────────────

\* Every enqueued keeper eventually completes.
NoStarvation ==
    \A k \in Keepers : k \in completed

EventualProgress == <>NoStarvation

\* ── Bug Model: timeout without slot release ────────────

BuggyTimeout(k) ==
    /\ active = k
    /\ slot_stuck' = TRUE  \* Slot permanently stuck
    \* active is NOT cleared — the bug
    /\ UNCHANGED <<queue, active, completed>>

NextBuggy ==
    \/ \E k \in Keepers : Enqueue(k)
    \/ Dequeue
    \/ SlotRelease
    \/ \E k \in Keepers : BuggyTimeout(k)

SpecBuggy == Init /\ [][NextBuggy]_vars /\ WF_vars(Dequeue) /\ WF_vars(SlotRelease)

\* In the buggy model, starvation occurs.
NeverStuck == ~slot_stuck

====
