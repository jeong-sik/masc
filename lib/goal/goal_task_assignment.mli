(** RFC-0267 Phase 2 — explicit, validated task->goal assignment.

    Single backend entry point shared by the MCP tool [masc_task_set_goal]
    and the dashboard HTTP route (POST /api/v1/dashboard/tasks/assign-goal),
    so the precondition checks are written once instead of duplicated at each
    surface. The link is persisted in the [goal_task_links] registry
    ([Workspace_goal_index]); the task record carries no goal_id field. *)

type set_task_goal_error =
  | Unknown_task of string
  | Unknown_goal of string
  | Already_assigned of
      { task_id : string
      ; existing_goal_ids : string list
      }

val set_task_goal_error_to_string : set_task_goal_error -> string

val set_task_goal :
  Workspace_utils.config ->
  task_id:string ->
  goal_id:string ->
  (unit, set_task_goal_error) result
(** [set_task_goal config ~task_id ~goal_id] links an existing, currently
    goalless task to an existing goal.

    - [Error (Unknown_task _)] — no task with [task_id] in the backlog.
    - [Error (Unknown_goal _)] — no goal with [goal_id] in the goal store.
    - [Error (Already_assigned _)] — the task already carries one or more
      goal links; reassignment/unlink is out of scope (RFC-0267 §4, which
      keeps Phase 2 strictly additive for goalless tasks).
    - [Ok ()] — the link was written (the registry write is idempotent and
      file-locked).

    Neither an unknown task nor an unknown goal is silently tolerated: both
    are returned as typed errors rather than mapped to a permissive default. *)
