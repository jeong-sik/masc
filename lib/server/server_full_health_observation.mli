(** Immutable observations served by [/health?full=1]. Clocks, placeholder
    acquisition, refresh ownership and publication effects belong to the caller. *)

type snapshot = {
  workspace_epoch : Mcp_server.Workspace_scope_epoch.t option;
  fields : (string * Yojson.Safe.t) list;
  computed_at : float;
  duration_ms : int;
  failure : Proactive_refresh.failure option;
  stale_since_ts : float option;
  last_good_available : bool;
  section_timings : (string * int) list;
}
(** [computed_at] is when the served measurement completed. [stale_since_ts]
    is the first invalidation or failure since a successful current refresh;
    dirty successes advance the measurement without ending that stale period. *)

type t = private {
  snapshot : snapshot option;
  consecutive_failures : int;
}
(** [None] means no observation has been published, including no cold failure
    placeholder. *)

val empty : t

val publish : snapshot -> t -> t
(** Replace the observation and reset consecutive failures, keeping the supplied
    stale metadata. The caller routes failed observations through [fail]. *)

val publish_dirty : since:float -> snapshot -> t -> t
(** Publish a successful invalidated scan, retaining the earlier of [since] and
    the previous observation's stale time. Consecutive failures reset. *)

val invalidate : now:float -> t -> t
(** Mark an existing observation stale without moving its first stale time or
    changing failure evidence. No observation is created for an empty state. *)

val fail :
  now:float ->
  failure:Proactive_refresh.failure ->
  cold_fields:(string * Yojson.Safe.t) list ->
  critical_threshold:int ->
  t -> t * bool
(** Preserve the prior fields, measurement time, duration, section timings and
    last-good availability while recording a new failure. The first stale time
    survives repeated failures. [cold_fields] is used only when no observation
    exists: callers acquire the current placeholder only in that case, and can
    otherwise supply the existing fields without acquiring a placeholder.

    The boolean is true exactly when this failure's new consecutive count
    equals [critical_threshold]. The caller emits the corresponding metric and
    fleet degradation effects; this module performs neither. *)
