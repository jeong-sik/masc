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

(** True when the task's structured [goal_id] field matches. *)
val task_matches_goal : goal_id:string -> Masc_domain.task -> bool

(** Alias for {!task_matches_goal}; retained for call sites that need the
    predicate name to be explicit about structured linkage. *)
val task_has_goal_id : goal_id:string -> Masc_domain.task -> bool

(** Check whether a goal's tasks have converged.

    Returns [Some signal] when convergence or stagnation is detected,
    [None] when work is still in progress.

    @param goal_id  The goal whose tasks to evaluate.
    @param tasks    All tasks in the room, filtered internally by explicit
                    [task.goal_id].
    @param stagnation_threshold  Number of iterations without progress before
                                 emitting [StagnationDetected]. Defaults to [5].
    @param iterations_without_progress  Current count of iterations with no task
                                        completions. Caller is responsible for
                                        tracking this across invocations. *)
val check_convergence :
  goal_id:string ->
  tasks:Masc_domain.task list ->
  ?stagnation_threshold:int ->
  iterations_without_progress:int ->
  unit ->
  convergence_signal option
