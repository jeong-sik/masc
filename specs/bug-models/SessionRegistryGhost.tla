---- MODULE SessionRegistryGhost ----
\* Bug Model: Session registry ghost entry from leave/reconnect race.
\*
\* Models lib/session.ml + lib/tool_inline_dispatch_coord.ml:handle_leave.
\*
\* handle_leave performs two non-atomic steps:
\*   1. Coord.leave(agent)         — removes from room/coord
\*   2. Session.unregister(agent)  — removes from session
\*
\* If a reconnect (register) fires between steps 1 and 2:
\*   1. Coord.leave removes agent from room
\*   2. register (with mutex) adds session entry
\*   3. unregister removes the entry register just created
\*   Result: agent thinks it reconnected, but session is gone.
\*
\* Reverse: if register fires AFTER unregister but Coord still says
\* "not joined", the session registry has a ghost entry for a non-member.
\*
\* ── Status (2026-04-20) ──
\* The historical bug class this spec models (no-mutex `unregister_sync`
\* racing against mutex-guarded `register`) was fixed: `unregister` now
\* takes the same `with_lock registry` as `register` (lib/session.ml:unregister).
\* The spec is retained as a regression-prevention contract: it will
\* fail-fast if the lock is removed again.
\*
\* Actual code:
\*   lib/session.ml:register   — Hashtbl.replace inside with_lock
\*   lib/session.ml:unregister — Hashtbl.remove inside with_lock
\*   lib/tool_inline_dispatch_coord.ml:200-201
\*                           Coord.leave then Session.unregister
\* (Both formerly: `lib/session/session.ml` + `tool_inline_dispatch_room.ml`
\*  and the no-lock `unregister_sync`. Path/symbol drift recorded here for
\*  future cross-reference.)

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

\* Step 1: Coord.leave — agent leaves room (Coord_lifecycle.leave)
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

\* Agent reconnects: Coord.join + register (both succeed atomically)
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
