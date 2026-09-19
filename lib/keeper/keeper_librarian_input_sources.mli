(** Durable, non-checkpoint inputs shared by the direct and range-based
    Librarian producers. *)

val goal_context_for_task
  :  config:Workspace.config
  -> Keeper_id.Task_id.t option
  -> Keeper_librarian.goal_context

(** Counterpart evidence in [[after, before)]. [after = None] means that the
    selected range starts with this trace's current atom history. The stores
    retain their existing bounded read contract; this function only narrows
    that typed evidence to the selected turn interval. *)
val counterpart_observations_between
  :  base_dir:string
  -> keeper_name:string
  -> after:float option
  -> before:float
  -> Keeper_counterpart_observation.t list

val counterpart_observations_between_offloaded
  :  base_dir:string
  -> keeper_name:string
  -> after:float option
  -> before:float
  -> Keeper_counterpart_observation.t list
