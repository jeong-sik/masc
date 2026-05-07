(** Coord_task_capacity — RFC-0034.v2 per-goal task creation cap.

    Moved here from [lib/keeper/keeper_exec_task.ml] (introduced by #13981).
    By living in [lib/coord/], the cap helpers are reachable from all 5 task
    creation entrypoints without violating layering (coord ← keeper, but
    keeper ↛ coord-callers like [tool_task], [task_dispatch],
    [tool_inline_dispatch_coord], [operator/operator_control]).

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

(** Hard-coded cap (currently 3) — matches the original
    [Keeper_exec_task.keeper_task_create_goal_open_limit]. *)
val default_goal_open_limit : int

(** [check ?goal_id backlog] returns [None] when [add_task] may proceed,
    [Some err] when adding another open task linked to [goal_id] would
    exceed [default_goal_open_limit].

    When [goal_id = None] the check is a no-op (returns [None]) — orphan
    tasks bypass the per-goal cap. *)
val check : ?goal_id:string -> Masc_domain.backlog -> capacity_error option

(** [error_to_json_string err] serializes to the same JSON-string shape
    that [Keeper_exec_task.task_create_capacity_error_json] produced
    pre-#13981 → RFC-0034.v2 (key order: ok, error_kind, goal_id,
    open_task_count, limit, action, error). The [keeper_task_create]
    MCP response surface is preserved. *)
val error_to_json_string : capacity_error -> string

(** [rejection_for_add_task ?goal_id backlog] is the [?reject_if]
    callback passed to [Coord_task.add_task]: returns [None] on success
    or [Some message] when the cap would be exceeded. *)
val rejection_for_add_task : ?goal_id:string -> Masc_domain.backlog -> string option
