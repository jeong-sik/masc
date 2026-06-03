(** Workspace_goal_index — Reverse index from goal_id to linked tasks.

    Eliminates O(n) linear scans in [validate_goal_completion_ready]
    (workspace_goals.ml) and [open_task_count_for_goal]
    (workspace_task_capacity.ml) by building a Hashtbl-based reverse
    index on demand from a task list.

    The index is ephemeral (not persisted): rebuild from the current
    task list each time it is needed. *)

open Masc_domain

(** Build a reverse index from goal_id to its linked tasks.
    Tasks with [goal_id = None] are excluded from the index. *)
let build_goal_task_index (tasks : task list) : (string, task list) Hashtbl.t =
  let tbl = Hashtbl.create 16 in
  List.iter (fun (task : task) ->
    match task.goal_id with
    | None -> ()
    | Some goal_id ->
      let existing = try Hashtbl.find tbl goal_id with Not_found -> [] in
      Hashtbl.replace tbl goal_id (task :: existing)
  ) tasks;
  tbl
;;

(** Find all tasks linked to a specific goal.
    Returns [[]] when no tasks are linked to the given [goal_id]. *)
let tasks_for_goal (index : (string, task list) Hashtbl.t) ~goal_id : task list =
  try Hashtbl.find index goal_id with Not_found -> []
;;

(** Count open (non-terminal) tasks for a goal using a pre-built index.
    O(k) where k = tasks linked to the goal, instead of O(n) full scan. *)
let open_task_count_for_goal_indexed
      (index : (string, task list) Hashtbl.t)
      ~goal_id
      : int
  =
  let linked = tasks_for_goal index ~goal_id in
  List.fold_left
    (fun count (task : task) ->
       if not (task_status_is_terminal task.task_status)
       then count + 1
       else count)
    0
    linked
;;
