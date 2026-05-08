(** Keeper_lifecycle_audit — in-memory ring buffer for keeper lifecycle events.

    Stores the last 50 lifecycle events per keeper for operator dashboards.
    Thread-safe; records survive for the process lifetime.

    @since #12798 *)

val record :
  keeper_name:string ->
  event_name:string ->
  phase:string option ->
  detail:string ->
  unit
(** [record ~keeper_name ~event_name ~phase ~detail] appends an event to the
    per-keeper ring buffer.  Called by
    [Cascade_events.publish_keeper_lifecycle] and the supervisor's
    [publish_lifecycle] helper so every lifecycle event is captured. *)

val recent_json : keeper_name:string -> limit:int -> Yojson.Safe.t
(** JSON array of the [limit] most recent lifecycle events for
    [keeper_name], newest first.  Each element is an object with:
    - [ts]     — Unix timestamp (float)
    - [event]  — lifecycle event name string
    - [phase]  — phase name or null
    - [detail] — free-text detail string *)
