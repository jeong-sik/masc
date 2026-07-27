(** Idempotent Goal-owned projection of durable [Task.Approved] events. *)

type t

type error =
  | Link_read_failed of string
  | Event_read_failed of string
  | Goal_update_failed of
      { goal_id : string
      ; detail : string
      }
  | Goal_event_failed of
      { goal_id : string
      ; detail : string
      }

type report =
  { eligible_goal_count : int
  ; replayed_event_count : int
  ; approved_task_count : int
  ; completed_goal_ids : string list
  ; last_seq : int
  }

val create : unit -> t
val last_seq : t -> int
val error_to_string : error -> string

val run :
  t ->
  Workspace_utils.config ->
  (report, error) result
(** Replays retained approved-task events on the first eligible pass and only
    events after the in-memory sequence on later passes. The in-memory sequence
    and approved-task set advance only after link reads, Goal updates, and
    canonical Goal event emission all succeed. *)
