(** Durable inputs a Librarian pass reads from disk: counterpart evidence for
    the range-based consumer and the Goal context of a task. *)

type read_error =
  | Chat_store_unreadable of string
  | External_attention_unreadable of Keeper_external_attention.read_error
  | External_cursor_failed of string

val read_error_to_string : read_error -> string

(** Complete counterpart evidence after [after] through [before], inclusive of
    [before]. [after = None] means
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

(** The Goal criteria linked to [task], read from the authoritative
    goal-task link index and the Goal store. [None] is [No_task]. A task with
    no linked Goal is [Task_goals] with [Ok []]; an unreadable index, an
    unreadable store, or a link naming a missing Goal is [Task_goals] with
    [Error], so a read failure never looks like a goalless task. Reads disk;
    a caller on the main domain offloads it. *)
val goal_context_for_task
  :  config:Workspace.config
  -> Keeper_id.Task_id.t option
  -> Keeper_librarian.goal_context

val counterpart_observations_from : external_after:int -> base_dir:string -> keeper_name:string ->
  after:float option -> before:float -> (Keeper_counterpart_observation.t list * int, read_error) result
(** External rows follow durable append order from [external_after] and stop
    at the first row admitted after [before]; chat rows retain their existing
    turn-time interval. Both are interleaved by time without reordering the
    external rows. The returned count is the external snapshot boundary. *)
