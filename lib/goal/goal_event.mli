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

type ensure_outcome =
  | Emitted
  | Already_present

val ensure_phase :
  Workspace_utils.config ->
  goal_id:string ->
  phase:Goal_phase.t ->
  actor:string ->
  goal_updated_at:string ->
  ensure_outcome
(** Ensures exactly one canonical phase projection for a specific persisted
    Goal version. The existing Goal event log is the idempotence authority. *)
