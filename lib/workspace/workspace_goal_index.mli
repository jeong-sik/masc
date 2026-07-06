(** Workspace_goal_index — Reverse index from goal_id to linked tasks.

    Provides O(1) amortized lookup for tasks linked to a goal,
    replacing O(n) linear scans over the full task list. *)

type goal_task_links_write_error = string

type link_goalless_task_to_goal_error =
  | Already_linked_to_goals of string list
  | Link_write_failed of goal_task_links_write_error

val goal_task_links_read_failed_prefix : string
val goal_task_links_read_failed_message : string -> string
val goal_task_links_write_error_to_string : goal_task_links_write_error -> string

val link_goalless_task_to_goal_error_to_string :
  link_goalless_task_to_goal_error -> string

(** Build a reverse index from goal_id to its linked tasks.

    [goal_task_links] is the authoritative source of goal-task
    associations. Each entry is [(goal_id, [task_id; ...])]. Task IDs
    are resolved against the supplied [tasks] list.

    When [goal_task_links] is omitted, the index is empty. The old
    fallback of deriving links from [task.goal_id] was removed as part
    of the task↔goal boundary refactor. *)
val build_goal_task_index
  :  ?goal_task_links:(string * string list) list
  -> Masc_domain.task list
  -> (string, Masc_domain.task list) Hashtbl.t

(** Find all tasks linked to a specific goal.
    Returns [[]] when no tasks are linked to the given [goal_id]. *)
val tasks_for_goal
  :  (string, Masc_domain.task list) Hashtbl.t
  -> goal_id:string
  -> Masc_domain.task list

(** Count open (non-terminal) tasks for a goal using a pre-built index.
    O(k) where k = tasks linked to the goal, instead of O(n) full scan. *)
val open_task_count_for_goal_indexed
  :  (string, Masc_domain.task list) Hashtbl.t
  -> goal_id:string
  -> int

(** Build a reverse-reverse index from task_id to the list of goal_ids it is
    linked to. This is the complement of [build_goal_task_index] and is
    useful for keeper-side lookups that need to answer “which goals does this
    task belong to?” without storing [goal_id] on the task record. *)
val build_task_goal_index
  :  ?goal_task_links:(string * string list) list
  -> unit
  -> (string, string list) Hashtbl.t

(** Path to the persistent goal-task link registry. *)
val goal_task_links_path : Workspace_utils_backend_setup.config -> string

(** Path to the verified recovery copy of the persistent goal-task link
    registry. *)
val goal_task_links_recovery_path :
  Workspace_utils_backend_setup.config -> string

(** Read the persistent goal-task link registry. Missing registry files are
    treated as an empty link set. *)
val read_goal_task_links :
  Workspace_utils_backend_setup.config -> (string * string list) list

val read_goal_task_links_r :
  Workspace_utils_backend_setup.config ->
  ((string * string list) list, string) result

(** Persist the goal-task link registry. *)
val write_goal_task_links :
  Workspace_utils_backend_setup.config -> (string * string list) list -> unit

val write_goal_task_links_result :
  ?rollback_on_recovery_failure:bool ->
  ?previous_links:(string * string list) list ->
  Workspace_utils_backend_setup.config ->
  (string * string list) list ->
  (unit, goal_task_links_write_error) result

(** Remove all links for [goal_id] under the goal-task-links file lock. *)
val prune_links_for_goal :
  Workspace_utils_backend_setup.config -> goal_id:string -> unit

val prune_links_for_goal_result :
  Workspace_utils_backend_setup.config ->
  goal_id:string ->
  (unit, goal_task_links_write_error) result

(** Add one task-to-goal link to the persistent registry. *)
val link_task_to_goal :
  Workspace_utils_backend_setup.config -> goal_id:string -> task_id:string -> unit

val link_task_to_goal_result :
  Workspace_utils_backend_setup.config ->
  goal_id:string ->
  task_id:string ->
  (unit, goal_task_links_write_error) result

(** Remove one task-to-goal link from the persistent registry. *)
val unlink_task_from_goal_result :
  Workspace_utils_backend_setup.config ->
  goal_id:string ->
  task_id:string ->
  (unit, goal_task_links_write_error) result

module For_testing : sig
  val with_before_unlink_task_from_goal :
    (Workspace_utils_backend_setup.config ->
     goal_id:string ->
     task_id:string ->
     unit) ->
    (unit -> 'a) ->
    'a
end

(** Add one task-to-goal link only when [task_id] has no existing goal link.
    The read/check/write sequence runs under the goal-task-links file lock.
    Returns [Error (Already_linked_to_goals existing_goal_ids)] when the task
    is already linked and [Error (Link_write_failed msg)] when the registry
    could not be durably written and verified. *)
val link_goalless_task_to_goal :
  Workspace_utils_backend_setup.config ->
  goal_id:string ->
  task_id:string ->
  (unit, link_goalless_task_to_goal_error) result

(** Add multiple task-to-goal links to the persistent registry. *)
val link_tasks_to_goals :
  Workspace_utils_backend_setup.config -> (string * string option) list -> unit

val link_tasks_to_goals_result :
  Workspace_utils_backend_setup.config ->
  (string * string option) list ->
  (unit, goal_task_links_write_error) result

(** Build indexes using the persistent link registry for [config]. *)
val build_goal_task_index_for_config_result :
  Workspace_utils_backend_setup.config ->
  Masc_domain.task list ->
  ((string, Masc_domain.task list) Hashtbl.t, string) result

val build_goal_task_index_for_config :
  Workspace_utils_backend_setup.config ->
  Masc_domain.task list ->
  (string, Masc_domain.task list) Hashtbl.t

val build_task_goal_index_for_config_result :
  Workspace_utils_backend_setup.config ->
  ((string, string list) Hashtbl.t, string) result

val build_task_goal_index_for_config :
  Workspace_utils_backend_setup.config -> (string, string list) Hashtbl.t
