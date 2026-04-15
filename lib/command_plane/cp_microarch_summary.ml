module U = Yojson.Safe.Util

(** Signal classification thresholds for microarch health tones. *)
let rework_bad = 0.4
let rework_warn = 0.2
let scope_drift_bad = 0.5
let scope_drift_warn = 0.25
let spec_commit_warn = 0.5

type search_row = {
  strategy : string;
  readiness : string;
  status : Cp_types.operation_status;
  candidate_count : int;
  best_score : float option;
  workload_profile : string;
  stage : string option;
  artifact_scope_count : int;
  artifact_scope_key : string option;
}

let tone_of_threshold ~warn ~bad value =
  if value >= bad then "bad"
  else if value >= warn then "warn"
  else "ok"

let tone_of_inverse_threshold ~warn ~bad value =
  if value <= bad then "bad"
  else if value <= warn then "warn"
  else "ok"

let get_float_opt json key =
  match U.member key json with
  | `Float v -> Some v
  | `Int v -> Some (float_of_int v)
  | _ -> None

let get_int_default json key default =
  match U.member key json with
  | `Int v -> v
  | _ -> default

let pipeline_json ~stalled_count = `Assoc [
  ("stalled_cycles", `Int stalled_count);
]
let cache_json () = `Assoc []
let ooo_json ~pending ~in_flight = `Assoc [
  ("current_pending", `Int pending);
  ("current_in_flight", `Int in_flight);
]
let speculative_json () = `Assoc []

let search_fabric_json (rows : search_row list) =
  let best_first_rows =
    List.filter (fun row -> String.equal row.strategy "best_first_v1") rows
  in
  let legacy_rows =
    List.filter (fun row -> String.equal row.strategy "legacy") rows
  in
  let blocked_rows =
    List.filter (fun row -> String.equal row.readiness "blocked") best_first_rows
  in
  let ready_rows =
    List.filter (fun row -> String.equal row.readiness "ready") best_first_rows
  in
  let research_rows =
    List.filter (fun row -> String.equal row.workload_profile "research_pipeline") rows
  in
  let coding_rows =
    List.filter (fun row -> String.equal row.workload_profile "coding_task") rows
  in
  let avg_candidate_count =
    if best_first_rows = [] then 0.0
    else
      best_first_rows
      |> List.fold_left (fun acc row -> acc + row.candidate_count) 0
      |> float_of_int
      |> fun total -> total /. float_of_int (List.length best_first_rows)
  in
  let best_scores =
    best_first_rows
    |> List.filter_map (fun row -> row.best_score)
  in
  let avg_best_score =
    if best_scores = [] then 0.0
    else
      List.fold_left ( +. ) 0.0 best_scores
      /. float_of_int (List.length best_scores)
  in
  let quality_per_token =
    let scored =
      coding_rows
      |> List.filter_map (fun row ->
             Option.map
               (fun best_score ->
                 let denom = float_of_int (max 1 row.candidate_count) in
                 best_score /. denom)
               row.best_score)
    in
    if scored = [] then 0.0
    else
      List.fold_left ( +. ) 0.0 scored /. float_of_int (List.length scored)
  in
  let verification_gate_failures =
    coding_rows
    |> List.filter (fun row ->
           match row.stage with
           | Some ("verify" | "review") ->
               (match row.status with
                | Cp_types.Failed | Cancelled -> true
                | Active | Planned | Paused | Completed -> false)
           | _ -> false)
    |> List.length
  in
  let rework_rate =
    let rows_with_scope =
      coding_rows
      |> List.filter (fun row ->
             match row.artifact_scope_key with
             | Some key -> String.trim key <> ""
             | None -> false)
    in
    let duplicate_count =
      rows_with_scope
      |> List.fold_left
           (fun acc row ->
             match row.artifact_scope_key with
             | None -> acc
             | Some key ->
                 let current =
                   match List.assoc_opt key acc with Some count -> count | None -> 0
                 in
                 (key, current + 1)
                 :: List.remove_assoc key acc)
           []
      |> List.fold_left (fun acc (_, count) -> if count > 1 then acc + count else acc) 0
    in
    if rows_with_scope = [] then 0.0
    else
      float_of_int duplicate_count /. float_of_int (List.length rows_with_scope)
  in
  let artifact_scope_drift, artifact_scope_active =
    let scoped_rows =
      coding_rows
      |> List.filter (fun row ->
             match row.stage with
             | Some "decompose" -> false
             | _ -> true)
    in
    let active =
      scoped_rows
      |> List.filter (fun row -> row.artifact_scope_count > 0)
      |> List.length
    in
    let drifted =
      scoped_rows
      |> List.filter (fun row -> row.artifact_scope_count = 0)
      |> List.length
    in
    let drift =
      if scoped_rows = [] then 0.0
      else
        float_of_int drifted /. float_of_int (List.length scoped_rows)
    in
    (drift, active)
  in
  let top_stage =
    rows
    |> List.filter_map (fun row -> row.stage)
    |> List.sort String.compare
    |> List.find_opt (fun _ -> true)
  in
  `Assoc [
    ("total_operations", `Int (List.length rows));
    ("best_first_operations", `Int (List.length best_first_rows));
    ("legacy_operations", `Int (List.length legacy_rows));
    ("blocked_operations", `Int (List.length blocked_rows));
    ("ready_operations", `Int (List.length ready_rows));
    ("research_pipeline_operations", `Int (List.length research_rows));
    ("coding_task_operations", `Int (List.length coding_rows));
    ("avg_candidate_count", `Float avg_candidate_count);
    ("avg_best_score", `Float avg_best_score);
    ("quality_per_token", `Float quality_per_token);
    ("verification_gate_failures", `Int verification_gate_failures);
    ("rework_rate", `Float rework_rate);
    ("artifact_scope_drift", `Float artifact_scope_drift);
    ("artifact_scope_active", `Int artifact_scope_active);
    ("top_stage", Json_util.string_opt_to_json top_stage);
  ]

let signals_json ~(pipeline : Yojson.Safe.t) ~(cache : Yojson.Safe.t)
    ~(ooo : Yojson.Safe.t) ~(speculative : Yojson.Safe.t)
    ~(search_fabric : Yojson.Safe.t) =
  let pipeline_stalls = get_int_default pipeline "stalled_cycles" 0 in
  let cache_bus_traffic = get_int_default cache "bus_traffic" 0 in
  let cache_hit_rate = get_float_opt cache "l1_hit_rate" |> Option.value ~default:0.0 in
  let pending_ops = get_int_default ooo "current_pending" 0 in
  let in_flight = get_int_default ooo "current_in_flight" 0 in
  let avg_best_score = get_float_opt search_fabric "avg_best_score" |> Option.value ~default:0.0 in
  let best_first_ops = get_int_default search_fabric "best_first_operations" 0 in
  let blocked_ops = get_int_default search_fabric "blocked_operations" 0 in
  let quality_per_token =
    get_float_opt search_fabric "quality_per_token" |> Option.value ~default:0.0
  in
  let verification_gate_failures =
    get_int_default search_fabric "verification_gate_failures" 0
  in
  let rework_rate =
    get_float_opt search_fabric "rework_rate" |> Option.value ~default:0.0
  in
  let artifact_scope_drift =
    get_float_opt search_fabric "artifact_scope_drift" |> Option.value ~default:0.0
  in
  let artifact_scope_active =
    get_int_default search_fabric "artifact_scope_active" 0
  in
  let spec_active = get_int_default speculative "active_sessions" 0 in
  let spec_commit_rate = get_float_opt speculative "commit_rate" |> Option.value ~default:0.0 in
  `Assoc [
    ("issue_pressure", `Assoc [
      ("tone", `String (tone_of_threshold ~warn:1 ~bad:4 (pending_ops + blocked_ops)));
      ("pending_ops", `Int pending_ops);
      ("blocked_ops", `Int blocked_ops);
      ("in_flight_ops", `Int in_flight);
      ("pipeline_stalls", `Int pipeline_stalls);
    ]);
    ("cache_contention", `Assoc [
      ("tone", `String (if cache_bus_traffic = 0 then "ok"  (* no traffic = inactive, not bad *)
                        else if cache_bus_traffic >= 20 || cache_hit_rate < 0.2 then "bad"
                        else if cache_bus_traffic >= 5 || cache_hit_rate < 0.5 then "warn"
                        else "ok"));
      ("bus_traffic", `Int cache_bus_traffic);
      ("l1_hit_rate", `Float cache_hit_rate);
      ("invalidation_count", U.member "invalidation_count" cache);
    ]);
    ("scheduler_efficiency", `Assoc [
      ("tone", `String (if pending_ops > (max 1 in_flight) * 2 then "warn" else "ok"));
      ("current_pending", `Int pending_ops);
      ("current_in_flight", `Int in_flight);
      ("cdb_wakeups", U.member "cdb_wakeups" ooo);
      ("total_stolen", U.member "total_stolen" ooo);
    ]);
    ("routing_confidence", `Assoc [
      ( "tone",
        `String
          (if best_first_ops = 0 then "ok"
           else tone_of_inverse_threshold ~warn:60.0 ~bad:40.0 avg_best_score) );
      ("avg_best_score", `Float avg_best_score);
      ("avg_candidate_count", U.member "avg_candidate_count" search_fabric);
      ("best_first_operations", `Int best_first_ops);
    ]);
    ("quality_per_token", `Assoc [
      ( "tone",
        `String
          (if get_int_default search_fabric "coding_task_operations" 0 = 0 then "ok"
           else tone_of_inverse_threshold ~warn:40.0 ~bad:25.0 quality_per_token) );
      ("value", `Float quality_per_token);
      ("coding_task_operations", U.member "coding_task_operations" search_fabric);
    ]);
    ("verification_gate_failures", `Assoc [
      ("tone", `String (tone_of_threshold ~warn:1 ~bad:3 verification_gate_failures));
      ("count", `Int verification_gate_failures);
    ]);
    ("rework_rate", `Assoc [
      ("tone", `String (if rework_rate >= rework_bad then "bad" else if rework_rate >= rework_warn then "warn" else "ok"));
      ("value", `Float rework_rate);
    ]);
    ("artifact_scope_drift", `Assoc [
      ("tone", `String (if artifact_scope_active = 0 then "ok"  (* no tasks use artifact scopes = feature dormant *)
                        else if artifact_scope_drift >= scope_drift_bad then "bad"
                        else if artifact_scope_drift >= scope_drift_warn then "warn"
                        else "ok"));
      ("value", `Float artifact_scope_drift);
      ("active", `Int artifact_scope_active);
    ]);
    ("speculative_posture", `Assoc [
      ("tone", `String (if spec_active > 0 && spec_commit_rate < spec_commit_warn then "warn" else "ok"));
      ("active_sessions", `Int spec_active);
      ("commit_rate", `Float spec_commit_rate);
      ("total_speculations", U.member "total_speculations" speculative);
    ]);
  ]

let summary_json ?(pending_ops=0) ?(in_flight_ops=0) ?(stalled_count=0)
    ~(search_rows : search_row list) () =
  let pipeline = pipeline_json ~stalled_count in
  let cache = cache_json () in
  let ooo = ooo_json ~pending:pending_ops ~in_flight:in_flight_ops in
  let speculative = speculative_json () in
  let search_fabric = search_fabric_json search_rows in
  let signals =
    signals_json ~pipeline ~cache ~ooo ~speculative ~search_fabric
  in
  `Assoc [
    ("pipeline", pipeline);
    ("cache", cache);
    ("ooo", ooo);
    ("speculative", speculative);
    ("search_fabric", search_fabric);
    ("signals", signals);
  ]
