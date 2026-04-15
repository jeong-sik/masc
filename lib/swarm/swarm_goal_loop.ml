(** Swarm Goal Loop - N agents collaborating toward one measurable goal.

    Coordinator fiber periodically measures aggregate progress,
    re-plans and re-dispatches when targets are not met.

    The loop runs as:
      1. measure (metric_fn shell command)
      2. evaluate (goal condition check via Bounded.evaluate_condition)
      3. if met -> done
      4. if not met -> cancel stale tasks, re-plan via Goal_orchestrator, re-dispatch
      5. checkpoint via Swarm_checkpoint
      6. sleep interval, repeat

    @since 2.80.0 *)

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type aggregate_strategy =
  | All    (** All sub-metrics must meet condition *)
  | Any    (** At least one sub-metric meets condition *)
  | Average (** Average of all sub-metrics meets condition *)
[@@deriving yojson]

type swarm_goal_config = {
  goal_id : string;
  title : string;
  metric_fn : string;
  goal_expr : string;
  max_iterations : int;
  check_interval_sec : int;
  aggregate : aggregate_strategy;
}
[@@deriving yojson]

type iteration_status =
  | Running
  | GoalMet
  | MaxIterationsReached
  | Cancelled
  | Failed of string

let iteration_status_to_yojson = function
  | Running -> `String "running"
  | GoalMet -> `String "goal_met"
  | MaxIterationsReached -> `String "max_iterations_reached"
  | Cancelled -> `String "cancelled"
  | Failed msg -> `Assoc [("failed", `String msg)]

let iteration_status_of_yojson = function
  | `String "running" -> Ok Running
  | `String "goal_met" -> Ok GoalMet
  | `String "max_iterations_reached" -> Ok MaxIterationsReached
  | `String "cancelled" -> Ok Cancelled
  | `Assoc [("failed", `String msg)] -> Ok (Failed msg)
  | _ -> Error "Unknown iteration_status"

type iteration_record = {
  iteration : int;
  measured_at : string;
  metric_value : float;
  goal_met : bool;
  tasks_cancelled : int;
  tasks_created : int;
  action : string;
}
[@@deriving yojson]

type loop_state = {
  config : swarm_goal_config;
  status : iteration_status;
  current_iteration : int;
  history : iteration_record list;
  started_at : string;
  last_check_at : string option;
}
[@@deriving yojson]

(** Shared cancellation flag for external loop cancellation.
    Set cancelled to true from another fiber to request graceful stop.
    Uses [Atomic.t] for fiber-safe cross-fiber visibility in OCaml 5. *)
type cancel_token = { cancelled : bool Atomic.t }

let make_cancel_token () = { cancelled = Atomic.make false }

(* ================================================================ *)
(* Metric measurement                                               *)
(* ================================================================ *)

let measure_metric metric_fn =
  match Autoresearch_metric.validate_metric_fn metric_fn with
  | Error e -> Error e
  | Ok metric_fn ->
  try
    let status, raw_output =
      Process_eio.run_argv_with_status ~timeout_sec:60.0
        ["sh"; "-c"; metric_fn]
    in
    let output = String.trim raw_output in
    match status with
    | Unix.WEXITED 0 ->
        (match Float.of_string_opt output with
         | Some v -> Ok v
         | None -> Error (Printf.sprintf "metric_fn output not a float: %S" output))
    | Unix.WEXITED code ->
        Error (Printf.sprintf "metric_fn exited with code %d" code)
    | _ ->
        Error "metric_fn terminated abnormally"
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Error (Printf.sprintf "metric_fn failed: %s" (Printexc.to_string exn))

(* ================================================================ *)
(* Goal expression parsing and evaluation                           *)
(* ================================================================ *)

type goal_op = Gte | Lte | Gt | Lt | Eq | Neq

let parse_goal_expr expr =
  let expr = String.trim expr in
  let try_op op_str op =
    match String.split_on_char ' ' expr with
    | [_lhs; op_s; rhs] when String.equal op_s op_str ->
        (match Float.of_string_opt rhs with
         | Some target -> Some (op, target)
         | None -> None)
    | _ -> None
  in
  (* Try operators in order of specificity: >= before >, <= before < *)
  let operators = [
    (">=", Gte); ("<=", Lte); ("!=", Neq);
    (">", Gt); ("<", Lt); ("==", Eq);
  ] in
  List.find_map (fun (s, op) -> try_op s op) operators

let evaluate_goal op target value =
  match op with
  | Gte -> value >= target
  | Lte -> value <= target
  | Gt -> value > target
  | Lt -> value < target
  | Eq -> Float.equal value target
  | Neq -> not (Float.equal value target)

(* ================================================================ *)
(* Aggregate evaluation (All / Any / Average)                       *)
(* ================================================================ *)

let evaluate_aggregate strategy ~aggregate_goal_expr metrics =
  let count = max 1 (List.length metrics) in
  let sum = List.fold_left (fun acc (v, _) -> acc +. v) 0.0 metrics in
  let avg = sum /. Float.of_int count in
  match strategy with
  | All ->
      let all_met = List.for_all (fun (_, met) -> met) metrics in
      (avg, all_met)
  | Any ->
      let any_met = List.exists (fun (_, m) -> m) metrics in
      (avg, any_met)
  | Average ->
      let goal_met =
        match parse_goal_expr aggregate_goal_expr with
        | Some (op, target) -> evaluate_goal op target avg
        | None -> false
      in
      (avg, goal_met)

(* ================================================================ *)
(* Re-plan: cancel incomplete tasks, build new dispatch plan        *)
(* ================================================================ *)

let cancel_incomplete_tasks config ~agent_name =
  let backlog = Coord.read_backlog config in
  let cancelled = ref 0 in
  let tasks =
    List.map
      (fun (task : Types.task) ->
        match task.task_status with
        | Types.Todo | Types.Claimed _ | Types.InProgress _ ->
            incr cancelled;
            { task with task_status = Types.Cancelled { cancelled_by = agent_name; cancelled_at = Types.now_iso (); reason = Some "swarm goal loop re-plan" } }
        | _ -> task)
      backlog.tasks
  in
  let new_backlog : Types.backlog =
    { tasks; last_updated = Types.now_iso (); version = backlog.version + 1 }
  in
  Coord.write_backlog config new_backlog;
  !cancelled

let re_plan_and_dispatch config ~agent_name ~goals =
  let opts : Goal_orchestrator.build_options =
    {
      requested_depth = 2;
      effective_depth = 2;
      child_limit = 8;
      grandchild_limit = 16;
      fanout_short = 4;
      fanout_mid = 2;
      fanout_long = 2;
    }
  in
  let plan = Goal_orchestrator.build_plan ~goals opts in
  Goal_orchestrator.execute_plan config ~agent_name plan

(* ================================================================ *)
(* Main loop                                                        *)
(* ================================================================ *)

let make_initial_state config =
  {
    config;
    status = Running;
    current_iteration = 0;
    history = [];
    started_at = Types.now_iso ();
    last_check_at = None;
  }

let run_one_iteration state config ~agent_name ~goals =
  let iteration = state.current_iteration + 1 in
  match measure_metric state.config.metric_fn with
  | Error e ->
      let record =
        {
          iteration;
          measured_at = Types.now_iso ();
          metric_value = Float.nan;
          goal_met = false;
          tasks_cancelled = 0;
          tasks_created = 0;
          action = Printf.sprintf "measurement_failed: %s" e;
        }
      in
      { state with
        current_iteration = iteration;
        history = record :: state.history;
        last_check_at = Some (Types.now_iso ());
        status = if iteration >= state.config.max_iterations then Failed e else Running;
      }
  | Ok metric_value ->
      let goal_met =
        match parse_goal_expr state.config.goal_expr with
        | Some (op, target) -> evaluate_goal op target metric_value
        | None -> false
      in
      if goal_met then
        let record =
          {
            iteration;
            measured_at = Types.now_iso ();
            metric_value;
            goal_met = true;
            tasks_cancelled = 0;
            tasks_created = 0;
            action = "goal_met";
          }
        in
        { state with
          current_iteration = iteration;
          history = record :: state.history;
          last_check_at = Some (Types.now_iso ());
          status = GoalMet;
        }
      else if iteration >= state.config.max_iterations then
        let record =
          {
            iteration;
            measured_at = Types.now_iso ();
            metric_value;
            goal_met = false;
            tasks_cancelled = 0;
            tasks_created = 0;
            action = "max_iterations_reached";
          }
        in
        { state with
          current_iteration = iteration;
          history = record :: state.history;
          last_check_at = Some (Types.now_iso ());
          status = MaxIterationsReached;
        }
      else begin
        let tasks_cancelled = cancel_incomplete_tasks config ~agent_name in
        let summary = re_plan_and_dispatch config ~agent_name ~goals in
        let record =
          {
            iteration;
            measured_at = Types.now_iso ();
            metric_value;
            goal_met = false;
            tasks_cancelled;
            tasks_created = summary.created_task_count;
            action = Printf.sprintf "re_planned (cancelled=%d, created=%d)"
                       tasks_cancelled summary.created_task_count;
          }
        in
        { state with
          current_iteration = iteration;
          history = record :: state.history;
          last_check_at = Some (Types.now_iso ());
          status = Running;
        }
      end

(** Run the swarm goal loop as a blocking Eio fiber.
    Returns the final loop_state when the goal is met, max iterations reached,
    or the loop is cancelled via [cancel_token]. *)
let run ~clock ?(cancel_token = { cancelled = Atomic.make false }) config ~room_config ~agent_name ~goals =
  let state = ref (make_initial_state config) in
  let keep_running () =
    if Atomic.get cancel_token.cancelled then begin
      state := { !state with status = Cancelled };
      false
    end else
      match (!state).status with
      | Running -> true
      | GoalMet | MaxIterationsReached | Cancelled | Failed _ -> false
  in
  while keep_running () do
    state := run_one_iteration !state room_config ~agent_name ~goals;
    (* Checkpoint after each iteration *)
    (match Swarm_checkpoint.save room_config with
     | Ok _ -> ()
     | Error e -> Log.Swarm.error "checkpoint error: %s" e);
    if keep_running () then
      Eio.Time.sleep clock (Float.of_int config.check_interval_sec)
  done;
  !state

(* ================================================================ *)
(* JSON response helpers                                            *)
(* ================================================================ *)

let state_to_json state =
  `Assoc [
    ("status", `String "ok");
    ("goal_id", `String state.config.goal_id);
    ("title", `String state.config.title);
    ("iteration", `Int state.current_iteration);
    ("max_iterations", `Int state.config.max_iterations);
    ("loop_status", iteration_status_to_yojson state.status);
    ("started_at", `String state.started_at);
    ("last_check_at",
     match state.last_check_at with
     | Some t -> `String t
     | None -> `Null);
    ("history",
     `List
       (state.history
        |> List.rev
        |> List.map iteration_record_to_yojson));
  ]
