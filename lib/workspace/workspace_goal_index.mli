(** Workspace_goal_index — Reverse index from goal_id to linked tasks.

    Provides O(1) amortized lookup for tasks linked to a goal,
    replacing O(n) linear scans over the full task list. *)

(** Build a reverse index from goal_id to its linked tasks.
    Tasks with [goal_id = None] are excluded from the index. *)
val build_goal_task_index
  :  Masc_domain.task list
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
