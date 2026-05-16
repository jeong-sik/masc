---- MODULE KeeperCompactionCooldown ----
\* Compact cooldown projection for post-turn continuity updates.
\*
\* This spec pins the contract behind:
\*   - lib/keeper/keeper_post_turn.ml: apply_continuity_summary
\*   - lib/keeper/keeper_compact_policy.ml: cooldown gate inputs
\*
\* Runtime intent:
\*   A post-turn checkpoint that does not contain a parseable [STATE] block
\*   must still advance the cooldown timestamp. Otherwise compaction policy
\*   sees an old last_continuity_update_ts and may compact every turn while
\*   metrics still look healthy.
\*
\* The model deliberately keeps STATE content out of scope. It only proves
\* that every post-turn continuity observation, including no-state, refreshes
\* the timestamp that the compaction gate consumes.

EXTENDS Naturals, TLC

CONSTANT MaxTime

VARIABLES
    now,
    last_continuity_ts,
    last_event

vars == <<now, last_continuity_ts, last_event>>

EventSet == {"Init", "State", "NoState", "NoCheckpoint", "Tick"}

TypeOK ==
    /\ now \in 0..MaxTime
    /\ last_continuity_ts \in 0..MaxTime
    /\ last_continuity_ts <= now
    /\ last_event \in EventSet

Init ==
    /\ now = 0
    /\ last_continuity_ts = 0
    /\ last_event = "Init"

PostTurnWithState ==
    /\ now < MaxTime
    /\ now' = now + 1
    /\ last_continuity_ts' = now'
    /\ last_event' = "State"

PostTurnNoState ==
    /\ now < MaxTime
    /\ now' = now + 1
    /\ last_continuity_ts' = now'
    /\ last_event' = "NoState"

NoCheckpoint ==
    /\ now < MaxTime
    /\ now' = now + 1
    /\ last_event' = "NoCheckpoint"
    /\ UNCHANGED <<last_continuity_ts>>

Tick ==
    /\ now < MaxTime
    /\ now' = now + 1
    /\ last_event' = "Tick"
    /\ UNCHANGED <<last_continuity_ts>>

Next ==
    \/ PostTurnWithState
    \/ PostTurnNoState
    \/ NoCheckpoint
    \/ Tick

Spec == Init /\ [][Next]_vars

StateAdvancesContinuity ==
    last_event = "State" => last_continuity_ts = now

NoStateAdvancesContinuity ==
    last_event = "NoState" => last_continuity_ts = now

NoCheckpointDoesNotInventContinuity ==
    last_event = "NoCheckpoint" => last_continuity_ts < now

Safety ==
    /\ TypeOK
    /\ StateAdvancesContinuity
    /\ NoStateAdvancesContinuity

\* Bug: no-state post-turn observations leave last_continuity_ts unchanged.
BuggyPostTurnNoState ==
    /\ now < MaxTime
    /\ now' = now + 1
    /\ last_event' = "NoState"
    /\ UNCHANGED <<last_continuity_ts>>

SpecBuggy == Init /\ [][Next \/ BuggyPostTurnNoState]_vars

====
