---- MODULE KeeperTurnSingleFlight ----
\* One straight timeline per Keeper lane.
\*
\* Every accepted chat or autonomous turn joins the same lane. The model has no
\* runtime queue rejection threshold: MaxArrivals only makes TLC's environment
\* finite. Different Keepers progress independently.

EXTENDS TLC, Naturals

CONSTANTS
    Keepers,
    MaxArrivals

ASSUME MaxArrivalsBound == MaxArrivals \in Nat /\ MaxArrivals >= 2

VARIABLES
    running,
    waiting,
    arrivals

vars == << running, waiting, arrivals >>

TypeOK ==
    /\ running \in [Keepers -> 0..2]
    /\ waiting \in [Keepers -> 0..MaxArrivals]
    /\ arrivals \in [Keepers -> 0..MaxArrivals]

SingleFlight == \A k \in Keepers : running[k] <= 1

Init ==
    /\ running = [k \in Keepers |-> 0]
    /\ waiting = [k \in Keepers |-> 0]
    /\ arrivals = [k \in Keepers |-> 0]

Enqueue(k) ==
    /\ arrivals[k] < MaxArrivals
    /\ arrivals' = [arrivals EXCEPT ![k] = @ + 1]
    /\ waiting' = [waiting EXCEPT ![k] = @ + 1]
    /\ UNCHANGED running

AdmitHead(k) ==
    /\ running[k] = 0
    /\ waiting[k] > 0
    /\ running' = [running EXCEPT ![k] = 1]
    /\ waiting' = [waiting EXCEPT ![k] = @ - 1]
    /\ UNCHANGED arrivals

TurnComplete(k) ==
    /\ running[k] = 1
    /\ running' = [running EXCEPT ![k] = 0]
    /\ UNCHANGED << waiting, arrivals >>

Next ==
    \E k \in Keepers :
        \/ Enqueue(k)
        \/ AdmitHead(k)
        \/ TurnComplete(k)

Spec == Init /\ [][Next]_vars

\* Bug witness: a second producer bypasses the lane and starts concurrently.
BypassLane(k) ==
    /\ running[k] = 1
    /\ running' = [running EXCEPT ![k] = 2]
    /\ UNCHANGED << waiting, arrivals >>

NextBuggy ==
    \/ Next
    \/ \E k \in Keepers : BypassLane(k)

SpecBuggy == Init /\ [][NextBuggy]_vars

====
