(** Coord_task_create — Dedup logic, add_task, batch_add_tasks.

    This module is [include]d by {!Coord_task}; all bindings are part of
    the public Coord interface.  Re-exports {!Coord_utils} and
    {!Coord_state}. *)

include module type of Coord_utils
include module type of Coord_state

(** {1 Task deduplication} *)

val normalize_title_for_dedup : string -> string
(** Normalize title for deduplication: lowercase, keep only alphanumeric+space. *)

val find_duplicate_task :
  Masc_domain.backlog -> title:string -> goal_id:string option -> string option
(** Check if a task with a similar title already exists in the backlog.
    Returns [Some existing_task_id] if a duplicate is found, [None] otherwise. *)

(** {1 Task creation} *)

val add_task :
  ?contract:Masc_domain.task_contract ->
  ?goal_id:string ->
  ?created_by:string ->
  ?reject_if:(Masc_domain.backlog -> string option) ->
  config -> title:string -> priority:int -> description:string -> string

val batch_add_tasks :
  ?created_by:string ->
  config -> (string * int * string * string option) list -> string

val batch_add_tasks_with_contracts :
  ?created_by:string ->
  config ->
  (string * int * string * Masc_domain.task_contract option * string option) list ->
  string

val batch_add_tasks_internal :
  ?created_by:string ->
  config ->
  (string * int * string * Masc_domain.task_contract option * string option) list ->
  string
(** Internal batch implementation shared by [batch_add_tasks] and
    [batch_add_tasks_with_contracts]. *)
