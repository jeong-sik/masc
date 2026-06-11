(** Dashboard_ops_iteration — ops iteration dashboard for keeper recovery tracking. *)

type iteration_summary = {
  keeper_name : string;
  fitness : float;
  total_tasks : int;
  completed_tasks : int;
  failed_tasks : int;
  task_completion_rate : float;
  error_rate : float;
  avg_completion_time_s : float;
  handoff_success_rate : float;
  unique_collaborators : string list;
}

type recovery_health = {
  keeper_name : string;
  recent_crash_count : int;
  restart_count : int;
  max_restarts : int;
  recovery_health_score : float;
  has_recent_crash : bool;
  is_stable : bool;
}

type ops_iteration_snapshot = {
  generated_at : float;
  keeper_count : int;
  active_keeper_count : int;
  degraded_keeper_count : int;
  iterations : iteration_summary list;
  recovery_entries : recovery_health list;
  fleet_health_score : float;
  degraded_agents : string list;
  avg_completion_rate : float;
  avg_error_rate : float;
}

(* ── Builders ── *)

let build_iteration_summary ~agent_name ~fitness ~total_tasks ~completed_tasks
    ~failed_tasks ~avg_completion_time_s ~task_completion_rate ~error_rate
    ~handoff_success_rate ~unique_collaborators =
  { keeper_name = agent_name
  ; fitness
  ; total_tasks
  ; completed_tasks
  ; failed_tasks
  ; task_completion_rate
  ; error_rate
  ; avg_completion_time_s
  ; handoff_success_rate
  ; unique_collaborators
  }

let build_recovery_health ~keeper_name ~recent_crash_count ~restart_count
    ~max_restarts =
  let recovery_health_score =
    if recent_crash_count = 0 then 1.0
    else Float.max 0.0 (1.0 -. (float_of_int recent_crash_count) *. 0.15)
  in
  let has_recent_crash = recent_crash_count > 0 in
  let is_stable = recent_crash_count = 0 && restart_count <= 1 in
  { keeper_name
  ; recent_crash_count
  ; restart_count
  ; max_restarts
  ; recovery_health_score
  ; has_recent_crash
  ; is_stable
  }

(* ── Fleet health ── *)

let compute_fleet_health_score ~iterations ~recovery_entries =
  let n = float_of_int (List.length iterations) in
  if n = 0.0 then 0.0
  else
    let sum_completion =
      List.fold_left (fun acc i -> acc +. i.task_completion_rate) 0.0 iterations
    in
    let sum_recovery =
      List.fold_left
        (fun acc r -> acc +. r.recovery_health_score)
        0.0 recovery_entries
    in
    let raw = (sum_completion +. sum_recovery) /. (n *. 2.0) in
    Float.min 1.0 (Float.max 0.0 raw)

let compute_degraded_agents ~iterations ~recovery_entries =
  let from_iterations =
    List.filter_map
      (fun i ->
        if i.error_rate > 0.25 || i.task_completion_rate < 0.5 then
          Some i.keeper_name
        else None)
      iterations
  in
  let from_recovery =
    List.filter_map
      (fun r -> if r.has_recent_crash then Some r.keeper_name else None)
      recovery_entries
  in
  List.sort_uniq String.compare (from_iterations @ from_recovery)

(* ── JSON ── *)

let iteration_summary_to_json (i : iteration_summary) : Yojson.Safe.t =
  `Assoc
    [ ("keeper_name", `String i.keeper_name)
    ; ("fitness", `Float i.fitness)
    ; ("total_tasks", `Int i.total_tasks)
    ; ("completed_tasks", `Int i.completed_tasks)
    ; ("failed_tasks", `Int i.failed_tasks)
    ; ("task_completion_rate", `Float i.task_completion_rate)
    ; ("error_rate", `Float i.error_rate)
    ; ("avg_completion_time_s", `Float i.avg_completion_time_s)
    ; ("handoff_success_rate", `Float i.handoff_success_rate)
    ; ( "unique_collaborators"
      , `List (List.map (fun c -> `String c) i.unique_collaborators) )
    ]

let recovery_health_to_json (r : recovery_health) : Yojson.Safe.t =
  `Assoc
    [ ("keeper_name", `String r.keeper_name)
    ; ("recent_crash_count", `Int r.recent_crash_count)
    ; ("restart_count", `Int r.restart_count)
    ; ("max_restarts", `Int r.max_restarts)
    ; ("recovery_health_score", `Float r.recovery_health_score)
    ; ("has_recent_crash", `Bool r.has_recent_crash)
    ; ("is_stable", `Bool r.is_stable)
    ]

let ops_iteration_snapshot_to_json (s : ops_iteration_snapshot) : Yojson.Safe.t =
  `Assoc
    [ ("generated_at", `Float s.generated_at)
    ; ("keeper_count", `Int s.keeper_count)
    ; ("active_keeper_count", `Int s.active_keeper_count)
    ; ("degraded_keeper_count", `Int s.degraded_keeper_count)
    ; ( "iterations"
      , `List (List.map iteration_summary_to_json s.iterations) )
    ; ( "recovery_entries"
      , `List (List.map recovery_health_to_json s.recovery_entries) )
    ; ("fleet_health_score", `Float s.fleet_health_score)
    ; ("degraded_agents", `List (List.map (fun a -> `String a) s.degraded_agents))
    ; ("avg_completion_rate", `Float s.avg_completion_rate)
    ; ("avg_error_rate", `Float s.avg_error_rate)
    ]

(* ── Aggregation ── *)

let aggregate_agent_data ~agent_name ~fitness ~metrics_total_tasks
    ~metrics_completed ~metrics_failed ~metrics_avg_time ~metrics_completion_rate
    ~metrics_error_rate ~metrics_handoff_rate ~metrics_collaborators :
    ops_iteration_snapshot =
  let iteration =
    build_iteration_summary ~agent_name ~fitness ~total_tasks:metrics_total_tasks
      ~completed_tasks:metrics_completed ~failed_tasks:metrics_failed
      ~avg_completion_time_s:metrics_avg_time
      ~task_completion_rate:metrics_completion_rate
      ~error_rate:metrics_error_rate
      ~handoff_success_rate:metrics_handoff_rate
      ~unique_collaborators:metrics_collaborators
  in
  let recovery =
    build_recovery_health ~keeper_name:agent_name ~recent_crash_count:metrics_failed
      ~restart_count:0 ~max_restarts:3
  in
  let fleet_health_score =
    compute_fleet_health_score ~iterations:[iteration] ~recovery_entries:[recovery]
  in
  let degraded_agents =
    compute_degraded_agents ~iterations:[iteration] ~recovery_entries:[recovery]
  in
  let active =
    if metrics_total_tasks > 0 then 1 else 0
  in
  let degraded_count = List.length degraded_agents in
  { generated_at = Unix.gettimeofday ()
  ; keeper_count = 1
  ; active_keeper_count = active
  ; degraded_keeper_count = degraded_count
  ; iterations = [iteration]
  ; recovery_entries = [recovery]
  ; fleet_health_score
  ; degraded_agents
  ; avg_completion_rate = metrics_completion_rate
  ; avg_error_rate = metrics_error_rate
  }