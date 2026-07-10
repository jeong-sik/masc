---- MODULE KeeperCompactionCooldown ----
\* Compaction cooldown projection.
\*
\* Contract anchors:
\*   - lib/keeper/keeper_compact_policy.ml: decide_compaction
\*   - keeper_meta.runtime.compaction_rt.last_ts
\*
\* Only an applied compaction advances the cooldown clock. Prompt text,
\* assistant replies, proactive turns, and failed/skipped compactions cannot
\* change it.

EXTENDS Naturals, TLC

CONSTANTS MaxTime, Cooldown

VARIABLES now, last_compaction_ts, last_event

vars == <<now, last_compaction_ts, last_event>>

EventSet == {"Init", "Applied", "BelowThreshold", "NoCheckpoint", "Tick"}

TypeOK ==
    /\ now \in 0..MaxTime
    /\ last_compaction_ts \in 0..MaxTime
    /\ last_compaction_ts <= now
    /\ last_event \in EventSet

Init ==
    /\ now = 0
    /\ last_compaction_ts = 0
    /\ last_event = "Init"

CooldownReady ==
    last_compaction_ts = 0 \/ now - last_compaction_ts >= Cooldown

ApplyCompaction ==
    /\ now < MaxTime
    /\ CooldownReady
    /\ now' = now + 1
    /\ last_compaction_ts' = now'
    /\ last_event' = "Applied"

NoCompaction(event) ==
    /\ now < MaxTime
    /\ now' = now + 1
    /\ last_event' = event
    /\ UNCHANGED <<last_compaction_ts>>

Next ==
    \/ ApplyCompaction
    \/ NoCompaction("BelowThreshold")
    \/ NoCompaction("NoCheckpoint")
    \/ NoCompaction("Tick")

Spec == Init /\ [][Next]_vars

AppliedRecordsTimestamp ==
    last_event = "Applied" => last_compaction_ts = now

NonAppliedDoesNotInventTimestamp ==
    last_event \in {"BelowThreshold", "NoCheckpoint", "Tick"}
    => last_compaction_ts < now

Safety == TypeOK /\ AppliedRecordsTimestamp

\* Bug: a skipped decision advances the cooldown timestamp even though no
\* compaction committed.
BuggyBelowThreshold ==
    /\ now < MaxTime
    /\ now' = now + 1
    /\ last_compaction_ts' = now'
    /\ last_event' = "BelowThreshold"

SpecBuggy == Init /\ [][Next \/ BuggyBelowThreshold]_vars

====
