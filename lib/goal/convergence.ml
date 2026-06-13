(** Convergence detection for goal-driven task execution.

    Pure deterministic logic — no Eio, no LLM calls.
    Evaluates whether a goal's associated tasks have reached
    a terminal state or progress has stalled. *)

type convergence_signal =
  | MetricMet of { metric : string; value : float; threshold : float }
  | AllSubTasksDone of { completed : int; total : int }
  | StagnationDetected of { iterations_without_progress : int }

type task_progress = {
  goal_id : string option;
  is_terminal : bool;
  is_completed : bool;
}

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

let progress_matches_goal ~goal_id progress =
  match progress.goal_id with
  | Some linked_goal_id -> String.equal linked_goal_id goal_id
  | None -> false

let check_convergence ~goal_id ~tasks ?(stagnation_threshold = 5)
    ~iterations_without_progress () =
  let goal_tasks = List.filter (progress_matches_goal ~goal_id) tasks in
  let total = List.length goal_tasks in
  if total = 0 then None
  else
    let completed =
      List_util.count_if (fun progress -> progress.is_completed) goal_tasks
    in
    let all_terminal =
      List.for_all (fun progress -> progress.is_terminal) goal_tasks
    in
    if all_terminal && completed = total then
      Some (AllSubTasksDone { completed; total })
    else if iterations_without_progress >= stagnation_threshold then
      Some (StagnationDetected { iterations_without_progress })
    else None
