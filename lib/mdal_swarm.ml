(** MDAL Swarm - Multi-agent parallel MDAL coordination.

    Runs N MDAL workers in parallel, each targeting a different component
    or sub-metric. A coordinator tracks aggregate progress and stops
    when the aggregate goal is met.

    Example: 8 agents each improving SSIM of different UI components,
    aggregate goal = average SSIM >= 0.95.

    @since 2.80.0 *)

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type aggregate_strategy =
  | All     (** Every worker must meet its individual goal *)
  | Any     (** At least one worker meets its goal *)
  | Average (** Aggregate (mean) of all worker metrics meets the goal *)
[@@deriving yojson]

type worker_spec = {
  worker_id : string;
  label : string;
  metric_fn : string;
  goal_expr : string;
  agent : string;
  max_iterations : int;
}
[@@deriving yojson]

type swarm_config = {
  swarm_id : string;
  title : string;
  workers : worker_spec list;
  aggregate_strategy : aggregate_strategy;
  aggregate_goal_expr : string;
  max_wall_time_sec : float option;
}
[@@deriving yojson]

type worker_result = {
  worker_id : string;
  label : string;
  final_metric : float;
  iterations_used : int;
  goal_met : bool;
  error : string option;
}
[@@deriving yojson]

type swarm_status =
  | Running
  | Completed
  | PartialSuccess
  | Failed
  | TimedOut
[@@deriving yojson]

type swarm_result = {
  swarm_id : string;
  title : string;
  status : swarm_status;
  aggregate_metric : float;
  aggregate_goal_met : bool;
  started_at : string;
  completed_at : string;
  worker_results : worker_result list;
  total_iterations : int;
}
[@@deriving yojson]

(* ================================================================ *)
(* Metric helpers                                                   *)
(* ================================================================ *)

let measure_metric_shell cmd =
  try
    let ic = Unix.open_process_in cmd in
    let output = In_channel.input_all ic |> String.trim in
    let status = Unix.close_process_in ic in
    match status with
    | Unix.WEXITED 0 ->
        (match Float.of_string_opt output with
         | Some v -> Ok v
         | None -> Error (Printf.sprintf "Not a float: %S" output))
    | Unix.WEXITED code ->
        Error (Printf.sprintf "Exit code %d" code)
    | _ -> Error "Abnormal termination"
  with exn ->
    Error (Printf.sprintf "Shell error: %s" (Printexc.to_string exn))

let compute_avg metrics =
  let count = max 1 (List.length metrics) in
  let sum = List.fold_left (fun acc (v, _) -> acc +. v) 0.0 metrics in
  sum /. Float.of_int count

let evaluate_aggregate strategy ~aggregate_goal_expr metrics =
  let avg = compute_avg metrics in
  match strategy with
  | All ->
      let all_met = List.for_all (fun (_, met) -> met) metrics in
      (avg, all_met)
  | Any ->
      let any_met = List.exists (fun (_, m) -> m) metrics in
      (avg, any_met)
  | Average ->
      let goal_met =
        match Swarm_goal_loop.parse_goal_expr aggregate_goal_expr with
        | Some (op, target) -> Swarm_goal_loop.evaluate_goal op target avg
        | None -> false
      in
      (avg, goal_met)

(* ================================================================ *)
(* Single worker loop (runs inside an Eio fiber)                    *)
(* ================================================================ *)

let run_single_worker ~clock (spec : worker_spec) : worker_result =
  let rec loop iteration last_metric =
    if iteration > spec.max_iterations then
      {
        worker_id = spec.worker_id;
        label = spec.label;
        final_metric = last_metric;
        iterations_used = iteration - 1;
        goal_met = false;
        error = None;
      }
    else
      match measure_metric_shell spec.metric_fn with
      | Error e ->
          {
            worker_id = spec.worker_id;
            label = spec.label;
            final_metric = last_metric;
            iterations_used = iteration;
            goal_met = false;
            error = Some e;
          }
      | Ok metric ->
          let goal_met =
            match Swarm_goal_loop.parse_goal_expr spec.goal_expr with
            | Some (op, target) -> Swarm_goal_loop.evaluate_goal op target metric
            | None -> false
          in
          if goal_met then
            {
              worker_id = spec.worker_id;
              label = spec.label;
              final_metric = metric;
              iterations_used = iteration;
              goal_met = true;
              error = None;
            }
          else begin
            (* Brief pause between iterations to avoid hammering *)
            Eio.Time.sleep clock 1.0;
            loop (iteration + 1) metric
          end
  in
  loop 1 Float.nan

(* ================================================================ *)
(* Swarm coordinator                                                *)
(* ================================================================ *)

(** Run all MDAL workers in parallel using Eio fibers.
    Returns aggregate swarm_result. *)
let run ~clock config =
  let started_at = Types.now_iso () in
  let worker_results =
    Eio.Fiber.List.map
      (fun spec -> run_single_worker ~clock spec)
      config.workers
  in
  let metrics_with_goals =
    List.map
      (fun (r : worker_result) -> (r.final_metric, r.goal_met))
      worker_results
  in
  let (aggregate_metric, aggregate_goal_met) =
    evaluate_aggregate config.aggregate_strategy
      ~aggregate_goal_expr:config.aggregate_goal_expr metrics_with_goals
  in
  let total_iterations =
    List.fold_left
      (fun acc (r : worker_result) -> acc + r.iterations_used)
      0 worker_results
  in
  let all_met = List.for_all (fun (r : worker_result) -> r.goal_met) worker_results in
  let any_error = List.exists (fun (r : worker_result) -> Option.is_some r.error) worker_results in
  let status =
    if aggregate_goal_met && all_met then Completed
    else if aggregate_goal_met then PartialSuccess
    else if any_error then Failed
    else PartialSuccess
  in
  {
    swarm_id = config.swarm_id;
    title = config.title;
    status;
    aggregate_metric;
    aggregate_goal_met;
    started_at;
    completed_at = Types.now_iso ();
    worker_results;
    total_iterations;
  }

(* ================================================================ *)
(* JSON response                                                    *)
(* ================================================================ *)

let result_to_json result =
  swarm_result_to_yojson result
