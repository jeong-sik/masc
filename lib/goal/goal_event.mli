(** Canonical durable Goal event producer over the existing
    [goal_events.jsonl] log. *)

val path : Workspace_utils.config -> string

val emit_phase :
  Workspace_utils.config ->
  goal_id:string ->
  phase:Goal_phase.t ->
  actor:string ->
  unit
(** Appends the canonical [goal_phase] event consumed by Goal timelines. *)
