(** Workspace_task_capacity — RFC-0034.v2 per-goal task creation cap.

    Moved here from the keeper task tool runtime helper introduced by #13981.
    By living in [lib/workspace/], the cap helpers are reachable from all 5 task
    creation entrypoints without violating layering (workspace ← keeper, but
    keeper ↛ workspace-callers like [tool_task], [task_dispatch],
    [mcp_tool_runtime_workspace], [operator/operator_control]).

    The cap rejects creation of a 4th open task linked to the same
    [goal_id]. Tasks with no [goal_id] (orphan tasks) are not capped. *)

(** Capacity violation, returned as [Some] when the per-goal cap would
    be exceeded by adding another task. *)
type capacity_error = {
  goal_id : string;
  open_task_count : int;
  limit : int;
  message : string;
}

(** Hard-coded cap (currently 3) — matches the original keeper task
    runtime helper value. *)
val default_goal_open_limit : int

val goal_task_links_read_failed_prefix : string
val goal_task_links_read_failed_message : string -> string

(** [check ?goal_id backlog] returns [None] when [add_task] may proceed,
    [Some err] when adding another open task linked to [goal_id] would
    exceed [default_goal_open_limit].

    When [goal_id = None] the check is a no-op (returns [None]) — orphan
    tasks bypass the per-goal cap. *)
val check : ?goal_id:string -> ?goal_task_links:(string * string list) list -> Masc_domain.backlog -> capacity_error option

(** Same as [check], reading the persistent goal-task link registry from
    [config]. *)
val check_for_config :
  Workspace_utils_backend_setup.config ->
  ?goal_id:string ->
  Masc_domain.backlog ->
  capacity_error option

val check_for_config_result :
  Workspace_utils_backend_setup.config ->
  ?goal_id:string ->
  Masc_domain.backlog ->
  (capacity_error option, string) result

(** [error_to_json_string err] serializes to the same JSON-string shape
    that the pre-RFC-0034.v2 keeper task runtime helper produced
    (key order: ok, error_kind, goal_id,
    open_task_count, limit, action, error). The [keeper_task_create]
    MCP response surface is preserved. *)
val error_to_json_string : capacity_error -> string

(** [rejection_for_add_task ?goal_id backlog] is the [?reject_if]
    callback passed to [Workspace_task.add_task]: returns [None] on success
    or [Some message] when the cap would be exceeded. *)
val rejection_for_add_task : ?goal_id:string -> Masc_domain.backlog -> string option

(** Same as [rejection_for_add_task], reading the persistent goal-task link
    registry from [config]. *)
val rejection_for_add_task_for_config :
  Workspace_utils_backend_setup.config ->
  ?goal_id:string ->
  Masc_domain.backlog ->
  string option
