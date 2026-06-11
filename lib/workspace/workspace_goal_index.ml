(** Workspace_goal_index — Reverse index from goal_id to linked tasks.

    Eliminates O(n) linear scans in [validate_goal_completion_ready]
    (workspace_goals.ml) and [open_task_count_for_goal]
    (workspace_task_capacity.ml) by building a Hashtbl-based reverse
    index on demand from explicit goal-task link mappings.

    The index is ephemeral (not persisted): rebuild from the current
    task list and external link registry each time it is needed. *)

open Masc_domain

(** Build a reverse index from goal_id to its linked tasks.

    [goal_task_links] is the authoritative source of goal-task
    associations. Each entry is [(goal_id, [task_id; ...])]. Task IDs
    are resolved against the supplied [tasks] list.

    When [goal_task_links] is omitted, the index is empty. The old
    fallback of deriving links from [task.goal_id] was removed as part
    of the task↔goal boundary refactor. *)
let build_goal_task_index
      ?(goal_task_links : (string * string list) list = [])
      (tasks : task list)
      : (string, task list) Hashtbl.t
  =
  let tbl = Hashtbl.create 16 in
  let task_by_id = Hashtbl.create (List.length tasks) in
  List.iter (fun (task : task) -> Hashtbl.replace task_by_id task.id task) tasks;
  List.iter
    (fun (goal_id, task_ids) ->
       let linked_tasks =
         List.filter_map
           (fun task_id ->
              try Some (Hashtbl.find task_by_id task_id) with Not_found -> None)
           task_ids
       in
       Hashtbl.replace tbl goal_id linked_tasks)
    goal_task_links;
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

(** Build a reverse-reverse index from task_id to the list of goal_ids it is
    linked to. This is the complement of [build_goal_task_index] and is
    useful for keeper-side lookups that need to answer “which goals does this
    task belong to?” without storing [goal_id] on the task record. *)
let build_task_goal_index
      ?(goal_task_links : (string * string list) list = [])
      ()
      : (string, string list) Hashtbl.t
  =
  let tbl = Hashtbl.create 16 in
  List.iter
    (fun (goal_id, task_ids) ->
       List.iter
         (fun task_id ->
            let existing = try Hashtbl.find tbl task_id with Not_found -> [] in
            Hashtbl.replace tbl task_id (goal_id :: existing))
         task_ids)
    goal_task_links;
  tbl
;;
