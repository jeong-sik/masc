(** Convergence detection for goal-driven task execution.

    Pure deterministic logic — no Eio, no LLM calls.
    Evaluates whether a goal's associated tasks have reached
    a terminal state or progress has stalled. *)

type convergence_signal =
  | MetricMet of
      { metric : string
      ; value : float
      ; threshold : float
      }
  | AllSubTasksDone of
      { completed : int
      ; total : int
      }
  | StagnationDetected of { iterations_without_progress : int }

let convergence_signal_to_yojson = function
  | MetricMet { metric; value; threshold } ->
    `Assoc
      [ "type", `String "metric_met"
      ; "metric", `String metric
      ; "value", `Float value
      ; "threshold", `Float threshold
      ]
  | AllSubTasksDone { completed; total } ->
    `Assoc
      [ "type", `String "all_sub_tasks_done"
      ; "completed", `Int completed
      ; "total", `Int total
      ]
  | StagnationDetected { iterations_without_progress } ->
    `Assoc
      [ "type", `String "stagnation_detected"
      ; "iterations_without_progress", `Int iterations_without_progress
      ]
;;

let goal_title_marker goal_id = Printf.sprintf "[goal:%s]" goal_id

let title_has_goal_marker ~goal_id title =
  let tag = goal_title_marker goal_id in
  let title_lower = String.lowercase_ascii title in
  let tag_lower = String.lowercase_ascii tag in
  (* Simple substring search *)
  let tag_len = String.length tag_lower in
  let title_len = String.length title_lower in
  if tag_len > title_len
  then false
  else (
    let found = ref false in
    for i = 0 to title_len - tag_len do
      if not !found
      then if String.sub title_lower i tag_len = tag_lower then found := true
    done;
    !found)
;;

let task_has_goal_id ~goal_id (task : Types.task) =
  match task.goal_id with
  | Some linked_goal_id -> String.equal linked_goal_id goal_id
  | None -> false
;;

(** A task belongs to a goal when its structured goal_id matches or its title
    carries the legacy [goal:<id>] marker. *)
let task_matches_goal ~goal_id (task : Types.task) =
  match task.goal_id with
  | Some _ -> task_has_goal_id ~goal_id task
  | None -> title_has_goal_marker ~goal_id task.title
;;

let is_terminal (task : Types.task) = Types.task_status_is_terminal task.task_status
let is_completed (task : Types.task) = Types.task_status_is_done task.task_status

let check_convergence
      ~goal_id
      ~tasks
      ?(stagnation_threshold = 5)
      ~iterations_without_progress
      ()
  =
  let goal_tasks = List.filter (task_matches_goal ~goal_id) tasks in
  let total = List.length goal_tasks in
  if total = 0
  then None
  else (
    let completed = List_util.count_if is_completed goal_tasks in
    let all_terminal = List.for_all is_terminal goal_tasks in
    if all_terminal && completed = total
    then Some (AllSubTasksDone { completed; total })
    else if iterations_without_progress >= stagnation_threshold
    then Some (StagnationDetected { iterations_without_progress })
    else None)
;;
