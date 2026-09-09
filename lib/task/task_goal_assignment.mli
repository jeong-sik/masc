(** RFC-0267 Phase 2 — explicit, validated task->goal assignment.

    Single backend entry point shared by the MCP tool [masc_task_set_goal]
    and the dashboard HTTP route (POST /api/v1/dashboard/tasks/assign-goal),
    so the precondition checks are written once instead of duplicated at each
    surface. The link is persisted in the [goal_task_links] registry
    ([Workspace_goal_index]); the task record carries no goal_id field.

    Lives in the task domain: a task->goal reference is the allowed direction,
    whereas hosting it in the goal leaf domain would be a goal->task coupling
    the domain-boundary ratchet rejects. *)

type set_task_goal_error =
  | Goal_source_unavailable of string
  | Backlog_read_failed of string
  | Unknown_task of string
  | Unknown_goal of string
  | Already_assigned of
      { task_id : string
      ; existing_goal_ids : string list
      }
  | Link_write_failed of string

val set_task_goal_error_to_string : set_task_goal_error -> string

val set_task_goal :
  Workspace_utils.config ->
  task_id:string ->
  goal_id:string ->
  (unit, set_task_goal_error) result
(** [set_task_goal config ~task_id ~goal_id] links an existing, currently
    goalless task to an existing goal.

    - [Error (Unknown_task _)] — no task with [task_id] in the backlog.
    - [Error (Backlog_read_failed _)] — the authoritative backlog cannot be
      read; a recovery snapshot is never used to authorize this mutation.
    - [Error (Goal_source_unavailable _)] — the primary Goal store cannot be read.
    - [Error (Unknown_goal _)] — no goal with [goal_id] in the primary Goal store.
    - [Error (Already_assigned _)] — the task already carries one or more
      goal links; reassignment/unlink is out of scope (RFC-0267 §4, which
      keeps Phase 2 strictly additive for goalless tasks).
    - [Error (Link_write_failed _)] — the task and goal are valid, but the
      registry update could not be durably written and verified.
    - [Ok ()] — Goal membership, task existence and the goalless precondition
      were held through the link write under Goal -> backlog -> links locks.

    Neither an unknown task nor an unknown goal is silently tolerated: both
    are returned as typed errors rather than mapped to a permissive default. *)

(** Goal-bound creation through the same Goal -> backlog -> links boundary.
    Goalless creation never reads the Goal store. *)
val add_task_with_result :
  ?contract:Masc_domain.task_contract -> ?goal_id:string -> ?created_by:string ->
  ?predecessor_task_id:string -> ?skills:Skill_reference.t list ->
  Workspace_utils.config -> title:string -> priority:int -> description:string ->
  (Workspace_task.add_task_success, Workspace_task.add_task_error) result

val batch_add_tasks_with_contracts_result :
  ?created_by:string -> Workspace_utils.config ->
  (string * int * string * Masc_domain.task_contract option * string option) list ->
  (Workspace_task.batch_add_tasks_success, Workspace_task.batch_add_tasks_error) result
