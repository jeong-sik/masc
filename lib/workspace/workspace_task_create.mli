(** Workspace_task_create — Dedup logic, add_task, batch_add_tasks.

    This module is [include]d by {!Workspace_task}; all bindings are part of
    the public Workspace interface.  Re-exports {!Workspace_utils} and
    {!Workspace_state}. *)

include module type of Workspace_utils
include module type of Workspace_state

(** {1 Task deduplication} *)

val normalize_title_for_dedup : string -> string
(** Normalize title for deduplication: lowercase, keep only alphanumeric+space. *)

val find_duplicate_task :
  Masc_domain.backlog -> title:string -> string option
(** Check if a task with a similar title already exists in the backlog.
    Returns [Some existing_task_id] if a duplicate is found, [None] otherwise. *)

(** {1 Task creation} *)

type add_task_success =
  { task_id : string
  ; summary : string
  ; title : string
  ; priority : int
  ; description : string
  }

type add_task_error =
  | Backlog_read_failed of string
  | Rejected of string
  | Duplicate of { title : string; existing_id : string }
  | Backlog_write_failed of string
  | Unexpected_error of string
  | Unknown_predecessor of string
      (** RFC-0323 W2: [predecessor_task_id] does not exist in the backlog *)
  | Predecessor_not_terminal of { predecessor_task_id : string; status : string }
      (** RFC-0323 W2: a re-run link requires a terminal (Done/Cancelled)
          predecessor *)

type batch_add_tasks_success =
  { task_ids : string list
  ; summary : string
  ; count : int
  }

type batch_add_tasks_error =
  | Batch_backlog_read_failed of string
  | Batch_backlog_write_failed of string
  | Batch_unexpected_error of string

val add_task_error_to_string : add_task_error -> string

val batch_add_tasks_error_to_string : batch_add_tasks_error -> string

val add_task_with_result :
  ?contract:Masc_domain.task_contract ->
  ?created_by:string ->
  ?predecessor_task_id:string ->
  ?reject_if:(Masc_domain.backlog -> string option) ->
  config ->
  title:string ->
  priority:int ->
  description:string ->
  (add_task_success, add_task_error) result

val add_task :
  ?contract:Masc_domain.task_contract ->
  ?created_by:string ->
  ?reject_if:(Masc_domain.backlog -> string option) ->
  config -> title:string -> priority:int -> description:string -> string

val batch_add_tasks :
  ?created_by:string ->
  config -> (string * int * string) list -> string

val batch_add_tasks_with_contracts :
  ?created_by:string ->
  config ->
  (string * int * string * Masc_domain.task_contract option) list ->
  string

val batch_add_tasks_with_contracts_result :
  ?created_by:string ->
  config ->
  (string * int * string * Masc_domain.task_contract option) list ->
  (batch_add_tasks_success, batch_add_tasks_error) result

val batch_add_tasks_internal :
  ?created_by:string ->
  config ->
  (string * int * string * Masc_domain.task_contract option) list ->
  string
(** Internal batch implementation shared by [batch_add_tasks] and
    [batch_add_tasks_with_contracts]. *)
