---- MODULE SessionRegistryGhost ----
\* Bug Model: Session registry ghost entry from leave/reconnect race.
\*
\* Models session.ml + tool_inline_dispatch_room.ml:handle_leave.
\*
\* handle_leave performs two non-atomic steps:
\*   1. Room.leave(agent)          — removes from room
\*   2. unregister_sync(agent)     — removes from session (NO mutex)
\*
\* If a reconnect (register) fires between steps 1 and 2:
\*   1. Room.leave removes agent from room
\*   2. register (with mutex) adds session entry
\*   3. unregister_sync (no mutex) removes the entry register just created
\*   Result: agent thinks it reconnected, but session is gone.
\*
\* Reverse: if register fires AFTER unregister_sync but Room still says
\* "not joined", the session registry has a ghost entry for a non-member.
\*
\* Actual code:
\*   session.ml:76     unregister_sync — Hashtbl.remove WITHOUT mutex
\*   session.ml:49-63  register — Hashtbl.replace WITH mutex
\*   tool_inline_dispatch_room.ml:333-334  Room.leave then unregister_sync

EXTENDS Naturals

VARIABLES
    room_status,      \* "joined" | "left"
    session_status,   \* "registered" | "unregistered"
    leave_phase,      \* "idle" | "room_left" | "done"
    reconnect_phase   \* "idle" | "registered" | "done"

vars == <<room_status, session_status, leave_phase, reconnect_phase>>

TypeOK ==
    /\ room_status \in {"joined", "left"}
    /\ session_status \in {"registered", "unregistered"}
    /\ leave_phase \in {"idle", "room_left", "done"}
    /\ reconnect_phase \in {"idle", "registered", "done"}

Init ==
    /\ room_status = "joined"
    /\ session_status = "registered"
    /\ leave_phase = "idle"
    /\ reconnect_phase = "idle"

\* ── Leave flow (2 non-atomic steps) ─────────────

\* Step 1: Room.leave — agent leaves room
LeaveStep1_RoomLeave ==
    /\ leave_phase = "idle"
    /\ room_status = "joined"
    /\ room_status' = "left"
    /\ leave_phase' = "room_left"
    /\ UNCHANGED <<session_status, reconnect_phase>>

\* Step 2: unregister_sync — remove session (no mutex)
LeaveStep2_Unregister ==
    /\ leave_phase = "room_left"
    /\ session_status' = "unregistered"
    /\ leave_phase' = "done"
    /\ UNCHANGED <<room_status, reconnect_phase>>

\* ── Reconnect flow (atomic — under mutex) ───────

\* Agent reconnects: Room.join + register (both succeed atomically)
ReconnectJoinAndRegister ==
    /\ reconnect_phase = "idle"
    /\ room_status' = "joined"
    /\ session_status' = "registered"
    /\ reconnect_phase' = "done"
    /\ UNCHANGED leave_phase

\* ── Heartbeat (updates existing session) ────────

\* Heartbeat only updates if session exists (no-op if unregistered)
Heartbeat ==
    /\ session_status = "registered"
    /\ UNCHANGED vars

Next ==
    \/ LeaveStep1_RoomLeave
    \/ LeaveStep2_Unregister
    \/ ReconnectJoinAndRegister
    \/ Heartbeat

Spec == Init /\ [][Next]_vars

\* ── Safety Invariant ────────────────────────────

\* Consistency: room and session must agree.
\* If agent is in room, session must be registered.
\* If agent left room and leave is complete, session must be unregistered.
NoGhostSession ==
    \* Ghost: in session registry but not in room (leave completed)
    ~(room_status = "left" /\ leave_phase = "done" /\ session_status = "registered")

NoOrphanMember ==
    \* Orphan: in room but not in session registry
    ~(room_status = "joined" /\ session_status = "unregistered")

ConsistencyInvariant ==
    /\ NoGhostSession
    /\ NoOrphanMember

\* ── Bug Model ───────────────────────────────────

\* Bug: reconnect interleaves between leave step 1 and step 2.
\*
\* Trace: LeaveStep1 -> ReconnectJoinAndRegister -> LeaveStep2
\*   After LeaveStep1: room=left, session=registered, leave_phase=room_left
\*   After Reconnect:  room=joined, session=registered, reconnect_phase=done
\*   After LeaveStep2: room=joined, session=UNREGISTERED <- ORPHAN!
\*
\* The leave's unregister_sync destroys the reconnect's fresh session.
\*
\* Clean model: leave is atomic (both steps in one action).

AtomicLeave ==
    /\ leave_phase = "idle"
    /\ room_status = "joined"
    /\ room_status' = "left"
    /\ session_status' = "unregistered"
    /\ leave_phase' = "done"
    /\ UNCHANGED reconnect_phase

NextClean ==
    \/ AtomicLeave
    \/ ReconnectJoinAndRegister
    \/ Heartbeat

SpecClean == Init /\ [][NextClean]_vars

\* Buggy = original non-atomic leave
SpecBuggy == Init /\ [][Next]_vars

====
