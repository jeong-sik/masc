---- MODULE SSEBroadcastBlock ----
\* Bug Model: SSE broadcast head-of-line blocking.
\*
\* Models sse.ml:broadcast_impl.
\*
\* Broadcast iterates a client snapshot and calls Eio.Stream.add
\* for each client. Eio.Stream is bounded (capacity 64 by default).
\* If a client's drain fiber has stopped (disconnect/slow network),
\* the stream fills up and Eio.Stream.add BLOCKS the broadcast fiber.
\*
\* Result: one dead client blocks event delivery to ALL other clients.
\* The failed-list cleanup runs AFTER the iteration completes, but
\* iteration is stuck on the blocking add.
\*
\* Actual code (verified 2026-04-20):
\*   lib/sse.ml:608  let broadcast_impl target json
\*   lib/sse.ml:637  Eio.Stream.add client.event_stream event (blocking!)
\*   lib/sse.ml:649  List.iter unregister !failed (too late)
\*
\* (Line drift since spec authoring: previously cited :471 and :483.
\*  ~165-line shift due to file growth. Recorded for cross-reference.)

EXTENDS Naturals

CONSTANTS
    NumClients,     \* Number of SSE clients (e.g. 3)
    StreamCapacity  \* Per-client stream capacity (e.g. 2 for tractable model)

VARIABLES
    stream_depth,   \* [1..NumClients] -> 0..StreamCapacity (events queued)
    client_alive,   \* [1..NumClients] -> TRUE | FALSE (draining or not)
    broadcast_idx,  \* 0..NumClients (0=idle, i=processing client i)
    broadcast_blocked  \* TRUE if broadcast is stuck on a full stream

vars == <<stream_depth, client_alive, broadcast_idx, broadcast_blocked>>

TypeOK ==
    /\ \A i \in 1..NumClients :
        /\ stream_depth[i] \in 0..StreamCapacity
        /\ client_alive[i] \in {TRUE, FALSE}
    /\ broadcast_idx \in 0..NumClients
    /\ broadcast_blocked \in {TRUE, FALSE}

Init ==
    /\ stream_depth = [i \in 1..NumClients |-> 0]
    /\ client_alive = [i \in 1..NumClients |-> TRUE]
    /\ broadcast_idx = 0
    /\ broadcast_blocked = FALSE

\* ── Actions ─────────────────────────────────────

\* Start broadcast: take snapshot, begin iteration at client 1
StartBroadcast ==
    /\ broadcast_idx = 0
    /\ ~broadcast_blocked
    /\ broadcast_idx' = 1
    /\ UNCHANGED <<stream_depth, client_alive, broadcast_blocked>>

\* Push event to current client (stream has room)
PushEvent ==
    /\ broadcast_idx > 0
    /\ broadcast_idx <= NumClients
    /\ ~broadcast_blocked
    /\ stream_depth[broadcast_idx] < StreamCapacity
    /\ stream_depth' = [stream_depth EXCEPT ![broadcast_idx] = @ + 1]
    /\ broadcast_idx' = IF broadcast_idx = NumClients THEN 0 ELSE broadcast_idx + 1
    /\ UNCHANGED <<client_alive, broadcast_blocked>>

\* Stream full -> broadcast BLOCKED (the bug)
PushBlocked ==
    /\ broadcast_idx > 0
    /\ broadcast_idx <= NumClients
    /\ ~broadcast_blocked
    /\ stream_depth[broadcast_idx] = StreamCapacity
    /\ broadcast_blocked' = TRUE
    /\ UNCHANGED <<stream_depth, client_alive, broadcast_idx>>

\* Blocked broadcast unblocks when client drains one event
UnblockBroadcast ==
    /\ broadcast_blocked
    /\ broadcast_idx > 0
    /\ client_alive[broadcast_idx]
    /\ stream_depth[broadcast_idx] > 0
    /\ stream_depth' = [stream_depth EXCEPT ![broadcast_idx] = @ - 1]
    /\ broadcast_blocked' = FALSE
    /\ UNCHANGED <<client_alive, broadcast_idx>>

\* Client drains an event from its stream (normal operation)
ClientDrain(i) ==
    /\ client_alive[i]
    /\ stream_depth[i] > 0
    \* Cannot drain the client that broadcast is currently blocked on
    \* (UnblockBroadcast handles that case)
    /\ ~(broadcast_blocked /\ broadcast_idx = i)
    /\ stream_depth' = [stream_depth EXCEPT ![i] = @ - 1]
    /\ UNCHANGED <<client_alive, broadcast_idx, broadcast_blocked>>

\* Client disconnects (stops draining)
ClientDisconnect(i) ==
    /\ client_alive[i]
    /\ client_alive' = [client_alive EXCEPT ![i] = FALSE]
    /\ UNCHANGED <<stream_depth, broadcast_idx, broadcast_blocked>>

Next ==
    \/ StartBroadcast
    \/ PushEvent
    \/ PushBlocked
    \/ UnblockBroadcast
    \/ \E i \in 1..NumClients :
        \/ ClientDrain(i)
        \/ ClientDisconnect(i)

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

\* ── Safety Invariant ────────────────────────────

\* Broadcast should never be permanently blocked.
\* Violated when: client disconnects while broadcast is blocked on its stream.
\* Dead client never drains -> UnblockBroadcast precondition (client_alive) fails.
NoPermanentBlock ==
    ~(broadcast_blocked /\
      broadcast_idx > 0 /\
      ~client_alive[broadcast_idx] /\
      stream_depth[broadcast_idx] = StreamCapacity)

\* ── Bug Model ───────────────────────────────────

\* Clean model: use Stream.add_nonblocking or try_add.
\* If stream is full, skip the client and add to failed list.

PushEventClean ==
    /\ broadcast_idx > 0
    /\ broadcast_idx <= NumClients
    /\ ~broadcast_blocked
    /\ IF stream_depth[broadcast_idx] < StreamCapacity
       THEN /\ stream_depth' = [stream_depth EXCEPT ![broadcast_idx] = @ + 1]
       ELSE \* Skip full stream (non-blocking)
            /\ UNCHANGED stream_depth
    /\ broadcast_idx' = IF broadcast_idx = NumClients THEN 0 ELSE broadcast_idx + 1
    /\ UNCHANGED <<client_alive, broadcast_blocked>>

NextClean ==
    \/ StartBroadcast
    \/ PushEventClean
    \* PushBlocked excluded — non-blocking push never blocks
    \/ \E i \in 1..NumClients :
        \/ ClientDrain(i)
        \/ ClientDisconnect(i)

SpecClean == Init /\ [][NextClean]_vars /\ WF_vars(NextClean)
SpecBuggy == Init /\ [][Next]_vars /\ WF_vars(Next)

====
