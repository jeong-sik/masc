---- MODULE RuntimeCheckpointOrder ----
\* Models runtime checkpoint ordering.
\*
\* Concrete code:
\*   - Runtime_server.apply_command Checkpoint
\*   - Runtime_store.save_snapshot
\*   - Runtime_store.append_event Checkpoint_saved
\*
\* The event log must never claim Checkpoint_saved unless the snapshot
\* write has already succeeded. An extra snapshot without an event is
\* acceptable after an append failure; an event without a snapshot is not.
\*
\* Bug model: BugAppendEventBeforeSnapshot models the old ordering where
\* Checkpoint_saved was appended before save_snapshot could fail.

VARIABLES
    phase,
    snapshot_saved,
    checkpoint_event_appended

vars == <<phase, snapshot_saved, checkpoint_event_appended>>

Phases == {"Init", "SnapshotSaved", "EventAppended", "Failed"}

TypeOK ==
    /\ phase \in Phases
    /\ snapshot_saved \in BOOLEAN
    /\ checkpoint_event_appended \in BOOLEAN

Init ==
    /\ phase = "Init"
    /\ snapshot_saved = FALSE
    /\ checkpoint_event_appended = FALSE

SaveSnapshot ==
    /\ phase = "Init"
    /\ phase' = "SnapshotSaved"
    /\ snapshot_saved' = TRUE
    /\ UNCHANGED checkpoint_event_appended

SnapshotWriteFails ==
    /\ phase = "Init"
    /\ phase' = "Failed"
    /\ UNCHANGED <<snapshot_saved, checkpoint_event_appended>>

AppendCheckpointEvent ==
    /\ phase = "SnapshotSaved"
    /\ snapshot_saved = TRUE
    /\ phase' = "EventAppended"
    /\ checkpoint_event_appended' = TRUE
    /\ UNCHANGED snapshot_saved

StutterDone ==
    /\ phase \in {"EventAppended", "Failed"}
    /\ UNCHANGED vars

Next ==
    \/ SaveSnapshot
    \/ SnapshotWriteFails
    \/ AppendCheckpointEvent
    \/ StutterDone

Spec == Init /\ [][Next]_vars

EventImpliesSnapshot ==
    checkpoint_event_appended => snapshot_saved

BugAppendEventBeforeSnapshot ==
    /\ phase = "Init"
    /\ phase' = "EventAppended"
    /\ checkpoint_event_appended' = TRUE
    /\ UNCHANGED snapshot_saved

NextBuggy ==
    \/ Next
    \/ BugAppendEventBeforeSnapshot

SpecBuggy == Init /\ [][NextBuggy]_vars

====
