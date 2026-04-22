(** Convergence detection for goal-driven task execution.

    Pure deterministic logic with no Eio dependency. Evaluates whether
    a goal's associated tasks have reached a terminal state. *)

(** Signal emitted when convergence is detected or progress has stalled. *)
type convergence_signal =
  | MetricMet of { metric : string; value : float; threshold : float }
  | AllSubTasksDone of { completed : int; total : int }
  | StagnationDetected of { iterations_without_progress : int }

(** Serialize a convergence signal to JSON. *)
val convergence_signal_to_yojson : convergence_signal -> Yojson.Safe.t

(** Legacy title marker retained for backward compatibility. *)
val goal_title_marker : string -> string

(** True when the task is structurally linked to the goal or carries the
    legacy [[goal:<id>]] title marker. *)
val task_matches_goal : goal_id:string -> Types.task -> bool

(** Check whether a goal's tasks have converged.

    Returns [Some signal] when convergence or stagnation is detected,
    [None] when work is still in progress.

    @param goal_id  The goal whose tasks to evaluate.
    @param tasks    All tasks in the room (filtered internally by explicit
                    [task.goal_id], with legacy title-tag fallback when
                    [goal_id] is absent).
    @param stagnation_threshold  Number of iterations without progress before
                                 emitting [StagnationDetected]. Defaults to [5].
    @param iterations_without_progress  Current count of iterations with no task
                                        completions. Caller is responsible for
                                        tracking this across invocations. *)
val check_convergence :
  goal_id:string ->
  tasks:Types.task list ->
  ?stagnation_threshold:int ->
  iterations_without_progress:int ->
  unit ->
  convergence_signal option
