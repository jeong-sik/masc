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
