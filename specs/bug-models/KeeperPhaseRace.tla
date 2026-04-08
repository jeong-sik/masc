---- MODULE KeeperPhaseRace ----
\* Bug Model: Keeper phase transition race condition.
\*
\* Models keeper_registry.ml phase state machine:
\*   running -> failing(n/MaxFails) -> cooldown -> running
\*   running -> handing_off -> idle
\*
\* Bug: concurrent TurnFail and RequestHandoff both attempt to
\* mutate phase, leading to inconsistent state (e.g. handing_off
\* with non-zero fail_count).

EXTENDS Naturals

CONSTANTS MaxFails  \* Threshold before cooldown (e.g. 10)

VARIABLES
    phase,          \* "running" | "failing" | "cooldown" | "handing_off" | "idle"
    fail_count,     \* 0..MaxFails
    handoff_req     \* Boolean: handoff requested

vars == <<phase, fail_count, handoff_req>>

TypeOK ==
    /\ phase \in {"running", "failing", "cooldown", "handing_off", "idle"}
    /\ fail_count \in 0..MaxFails
    /\ handoff_req \in {TRUE, FALSE}

Init ==
    /\ phase = "running"
    /\ fail_count = 0
    /\ handoff_req = FALSE

\* ── Normal transitions ─────────────────────────────────

TurnSucceed ==
    /\ phase \in {"running", "failing"}
    /\ phase' = "running"
    /\ fail_count' = 0
    /\ UNCHANGED handoff_req

TurnFail ==
    /\ phase \in {"running", "failing"}
    /\ fail_count < MaxFails
    /\ fail_count' = fail_count + 1
    /\ phase' = IF fail_count + 1 >= MaxFails THEN "cooldown" ELSE "failing"
    /\ UNCHANGED handoff_req

CooldownExpire ==
    /\ phase = "cooldown"
    /\ phase' = "running"
    /\ fail_count' = 0
    /\ UNCHANGED handoff_req

RequestHandoff ==
    /\ phase = "running"
    /\ handoff_req' = TRUE
    /\ phase' = "handing_off"
    /\ fail_count' = 0
    /\ UNCHANGED <<>>

HandoffComplete ==
    /\ phase = "handing_off"
    /\ phase' = "idle"
    /\ UNCHANGED <<fail_count, handoff_req>>

\* ── Clean Next ─────────────────────────────────────────

Next ==
    \/ TurnSucceed
    \/ TurnFail
    \/ CooldownExpire
    \/ RequestHandoff
    \/ HandoffComplete

Spec == Init /\ [][Next]_vars

\* ── Safety Invariants ──────────────────────────────────

\* Handoff phase must have zero fail count.
HandoffMeansClean ==
    phase = "handing_off" => fail_count = 0

\* Cooldown is only entered at MaxFails.
CooldownAtThreshold ==
    phase = "cooldown" => fail_count >= MaxFails

\* Idle can only follow handing_off.
IdleRequiresHandoff ==
    phase = "idle" => handoff_req = TRUE

\* ── Bug Model: Race between TurnFail and RequestHandoff ─

\* Bug: both TurnFail and RequestHandoff fire "simultaneously"
\* (interleaved without mutual exclusion). TurnFail increments
\* fail_count, then RequestHandoff transitions to handing_off
\* WITHOUT resetting fail_count.
BuggyRequestHandoff ==
    /\ phase \in {"running", "failing"}  \* Bug: accepts "failing" too
    /\ handoff_req' = TRUE
    /\ phase' = "handing_off"
    /\ UNCHANGED fail_count  \* Bug: does NOT reset fail_count

NextBuggy ==
    \/ TurnSucceed
    \/ TurnFail
    \/ CooldownExpire
    \/ BuggyRequestHandoff
    \/ HandoffComplete

SpecBuggy == Init /\ [][NextBuggy]_vars

====
