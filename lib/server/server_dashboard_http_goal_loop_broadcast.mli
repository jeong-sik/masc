(** RFC-0284: server-side change-gated SSE broadcast of the goal-loop OODA
    status.

    The goal-loop worker is an out-of-process Python OODA loop that only writes
    [<masc_dir>/goal-loop/status.json]; it cannot call the in-process
    [Sse.broadcast]. So the broadcast trigger lives here: a periodic tick reads
    the cached status, fingerprints its meaningful content (per-write volatile
    fields excluded), and broadcasts only when that content changed. The event
    bridges to the existing dashboard "goals" WS slice via
    [Server_mcp_transport_ws.dashboard_slice_for_sse_type], so no new WS slice
    is introduced. The change-detection pattern mirrors
    [Server_dashboard_http_namespace_truth]. See the [.ml] and RFC-0284 §3 for
    the full rationale.

    The change-fingerprint state (last-broadcast hash and its mutex) is
    intentionally module-private so callers cannot desynchronize it. *)

val goal_loop_broadcast_event_type : string
(** SSE event type carried by a goal-loop broadcast. Kept in sync with the
    [dashboard_slice_for_sse_type] bridge entry in [Server_mcp_transport_ws]
    that maps it onto the "goals" slice. *)

val goal_loop_broadcast_interval_s : float
(** Periodic refresh interval for the goal-loop status broadcast. *)

val goal_loop_broadcast_timeout_s : float
(** Per-refresh compute timeout. Must stay below
    {!goal_loop_broadcast_interval_s} so {!Proactive_refresh.start} does not
    clamp and warn on startup. *)

val goal_loop_snapshot_event : Yojson.Safe.t -> Yojson.Safe.t
(** [goal_loop_snapshot_event status] wraps [status] in the SSE envelope
    ([type] / [payload] / [ts_unix]) that {!broadcast_goal_loop_status} emits.
    Exposed for tests asserting the envelope shape. *)

val broadcast_goal_loop_status : Yojson.Safe.t -> bool
(** [broadcast_goal_loop_status status] broadcasts a
    {!goal_loop_broadcast_event_type} event carrying [status] to dashboard
    observers, but only when its meaningful content changed since the last
    broadcast (per-write volatile fields are excluded from the fingerprint).
    Returns [true] when an event was emitted, [false] when an unchanged status
    was skipped. *)

val start_goal_loop_refresh_loop :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  unit
(** [start_goal_loop_refresh_loop ~state ~sw ~clock] starts a periodic fiber
    that reads the cached goal-loop status and calls
    {!broadcast_goal_loop_status} on each tick (change-gated). *)
