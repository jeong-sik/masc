(** Keeper_ops_iteration — in-memory ring buffer tracking
    keeper recovery iterations for the ops dashboard.

    Records recovery events from
    {!Keeper_recording_error_state}, maintains a bounded
    (1024-slot) cyclic event buffer, and projects per-keeper
    aggregate statistics.

    The ops dashboard endpoint
    ([GET /dashboard/b/api/keepers/iteration]) reads the
    response via {!build_response}. *)

module T = Masc_dashboard_api_types.Iteration

(** {1 State} *)

type t
(** Opaque ring-buffer state. *)

val create : unit -> t
(** Create an empty iteration tracker. *)

val current_cycle : t -> int
(** Current iteration cycle number (incremented per
    {!step_cycle}). *)

(** {1 Recording} *)

val record_recovery :
  t ->
  keeper_name:string ->
  error_message:string ->
  ?tool_name:string ->
  ?phase:T.recovery_phase ->
  unit ->
  unit
(** Record a keeper recovery event. Auto-assigns an event
    id, pushes into the ring buffer, and updates per-keeper
    aggregate stats.

    - [keeper_name]: the recovering keeper's handle
    - [error_message]: original error text (truncated for stats)
    - [tool_name]: optional tool that failed
    - [phase]: defaults to {!T.recovery_phase.Detecting} *)

val resolve_event : t -> event_id:string -> duration_ms:int -> unit
(** Mark a recovery event as resolved. Updates event phase
    and per-keeper stats. No-op if already resolved/escalated. *)

val escalate_event : t -> event_id:string -> duration_ms:int -> unit
(** Mark a recovery event as escalated (could not auto-resolve).
    Updates event phase and per-keeper stats. No-op if already
    resolved/escalated. *)

val step_cycle : t -> unit
(** Advance to next iteration cycle. *)

(** {1 Projection} *)

val build_response :
  t ->
  workspace:string option ->
  T.response
(** Build the full ops iteration response from current state:
    - All events from the ring buffer (oldest first)
    - Per-keeper aggregate stats (total, active, resolved,
      escalated, avg duration, top error, last recovery)
    - Summary statistics for the workspace
    - Current cycle number

    Events are snapshotted at call time; callers should
    serialize the response immediately. *)