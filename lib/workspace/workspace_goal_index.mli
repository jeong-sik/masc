(** Workspace_goal_index — Reverse index from goal_id to linked tasks.

    Provides O(1) amortized lookup for tasks linked to a goal,
    replacing O(n) linear scans over the full task list. *)

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

(** Read the persistent goal-task link registry. Missing registry files are
    treated as an empty link set. *)
val read_goal_task_links :
  Workspace_utils_backend_setup.config -> (string * string list) list

val read_goal_task_links_r :
  Workspace_utils_backend_setup.config ->
  ((string * string list) list, string) result

(** Build the goal-task index from a single locked snapshot of the backlog and
    goal-task-link registry.  The lock order is backlog -> goal-task-links,
    matching task creation paths that write the backlog before adding links.
    Completion gates use this fail-closed variant instead of the fail-soft
    projection below. *)
val build_goal_task_index_for_config_checked :
  Workspace_utils_backend_setup.config ->
  ((string, Masc_domain.task list) Hashtbl.t, string) result

(** Persist the goal-task link registry. *)
val write_goal_task_links :
  Workspace_utils_backend_setup.config -> (string * string list) list -> unit

(** Remove all links for [goal_id] under the goal-task-links file lock. *)
val prune_links_for_goal :
  Workspace_utils_backend_setup.config -> goal_id:string -> unit

(** Add one task-to-goal link to the persistent registry. *)
val link_task_to_goal :
  Workspace_utils_backend_setup.config -> goal_id:string -> task_id:string -> unit

type link_goalless_task_checked_error =
  | Link_unknown_task
  | Link_unknown_goal
  | Link_registry_unreadable of string
  | Link_already_assigned of string list

(** Add one task-to-goal link and report registry failures.  Use this variant
    when the caller has just committed related task state and must compensate
    if the link registry cannot be updated. *)
val link_task_to_goal_result :
  Workspace_utils_backend_setup.config ->
  goal_id:string ->
  task_id:string ->
  (unit, link_goalless_task_checked_error) result

(** Add one task-to-goal link only when [task_id] has no existing goal link.
    The read/check/write sequence runs under the goal-task-links file lock.
    Returns [Error (Link_already_assigned existing_goal_ids)] when the task is
    already linked, or [Error (Link_registry_unreadable _)] when the registry
    cannot be read safely. *)
val link_goalless_task_to_goal :
  Workspace_utils_backend_setup.config ->
  goal_id:string ->
  task_id:string ->
  (unit, link_goalless_task_checked_error) result

(** Validate and add one task-to-goal link under the goal-task-links file lock.
    [task_exists] and [goal_exists] are callbacks so the workspace index stays
    independent from task/goal stores while callers can avoid a caller-side
    validate-then-write race around the registry update.  Registry read errors
    fail closed with [Link_registry_unreadable _] before any write. *)
val link_goalless_task_to_goal_checked :
  Workspace_utils_backend_setup.config ->
  goal_id:string ->
  task_id:string ->
  task_exists:(task_id:string -> bool) ->
  goal_exists:(goal_id:string -> bool) ->
  (unit, link_goalless_task_checked_error) result

(** Add multiple task-to-goal links to the persistent registry. *)
val link_tasks_to_goals :
  Workspace_utils_backend_setup.config -> (string * string option) list -> unit

(** Add multiple task-to-goal links under one registry lock and report registry
    failures.  The registry is written at most once; if it cannot be read, no
    link write is attempted. *)
val link_tasks_to_goals_result :
  Workspace_utils_backend_setup.config ->
  (string * string option) list ->
  (unit, link_goalless_task_checked_error) result

(** Build indexes using the persistent link registry for [config]. *)
val build_goal_task_index_for_config :
  Workspace_utils_backend_setup.config ->
  Masc_domain.task list ->
  (string, Masc_domain.task list) Hashtbl.t

val build_task_goal_index_for_config :
  Workspace_utils_backend_setup.config -> (string, string list) Hashtbl.t
