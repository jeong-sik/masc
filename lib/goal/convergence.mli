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

(** Goal-local view of task progress supplied by the task/workspace owner. *)
type task_progress = {
  goal_id : string option;
  is_terminal : bool;
  is_completed : bool;
}

(** Check whether a goal's tasks have converged.

    Returns [Some signal] when convergence or stagnation is detected,
    [None] when work is still in progress.

    @param goal_id  The goal whose tasks to evaluate.
    @param tasks    Already-loaded task progress projections, filtered
                    internally by explicit [goal_id].
    @param stagnation_threshold  Number of iterations without progress before
                                 emitting [StagnationDetected]. Defaults to [5].
    @param iterations_without_progress  Current count of iterations with no task
                                        completions. Caller is responsible for
                                        tracking this across invocations. *)
val check_convergence :
  goal_id:string ->
  tasks:task_progress list ->
  ?stagnation_threshold:int ->
  iterations_without_progress:int ->
  unit ->
  convergence_signal option
