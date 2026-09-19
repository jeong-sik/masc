(** Durable, non-checkpoint inputs shared by the direct and range-based
    Librarian producers. *)

val goal_context_for_task
  :  config:Workspace.config
  -> Keeper_id.Task_id.t option
  -> Keeper_librarian.goal_context

type read_error =
  | Chat_store_unreadable of string
  | External_attention_unreadable of string

val read_error_to_string : read_error -> string

(** Complete counterpart evidence in [[after, before)]. [after = None] means
    that the selected range starts with this trace's current atom history.
    Both append-only stores are read fail-closed: a cursor must not advance
    over a bounded tail or an unreadable row. *)
val counterpart_observations_between
  :  base_dir:string
  -> keeper_name:string
  -> after:float option
  -> before:float
  -> (Keeper_counterpart_observation.t list, read_error) result

val counterpart_observations_between_offloaded
  :  base_dir:string
  -> keeper_name:string
  -> after:float option
  -> before:float
  -> (Keeper_counterpart_observation.t list, read_error) result
