(** Convergence detection for goal-driven task execution.

    Pure deterministic logic — no Eio, no LLM calls.
    Evaluates whether a goal's associated tasks have reached
    a terminal state or progress has stalled. *)

type convergence_signal =
  | MetricMet of { metric : string; value : float; threshold : float }
  | AllSubTasksDone of { completed : int; total : int }
  | StagnationDetected of { iterations_without_progress : int }

let convergence_signal_to_yojson = function
  | MetricMet { metric; value; threshold } ->
      `Assoc
        [
          ("type", `String "metric_met");
          ("metric", `String metric);
          ("value", `Float value);
          ("threshold", `Float threshold);
        ]
  | AllSubTasksDone { completed; total } ->
      `Assoc
        [
          ("type", `String "all_sub_tasks_done");
          ("completed", `Int completed);
          ("total", `Int total);
        ]
  | StagnationDetected { iterations_without_progress } ->
      `Assoc
        [
          ("type", `String "stagnation_detected");
          ("iterations_without_progress", `Int iterations_without_progress);
        ]

let task_has_goal_id ~goal_id (task : Masc_domain.task) =
  match task.goal_id with
  | Some linked_goal_id -> String.equal linked_goal_id goal_id
  | None -> false

let task_matches_goal ~goal_id (task : Masc_domain.task) =
  task_has_goal_id ~goal_id task

let is_terminal (task : Masc_domain.task) =
  Masc_domain.task_status_is_terminal task.task_status

let is_completed (task : Masc_domain.task) =
  Masc_domain.task_status_is_done task.task_status

let check_convergence ~goal_id ~tasks ?(stagnation_threshold = 5)
    ~iterations_without_progress () =
  let goal_tasks = List.filter (task_matches_goal ~goal_id) tasks in
  let total = List.length goal_tasks in
  if total = 0 then None
  else
    let completed = List_util.count_if is_completed goal_tasks in
    let all_terminal = List.for_all is_terminal goal_tasks in
    if all_terminal && completed = total then
      Some (AllSubTasksDone { completed; total })
    else if iterations_without_progress >= stagnation_threshold then
      Some (StagnationDetected { iterations_without_progress })
    else None
