module U = Yojson.Safe.Util

type search_row = {
  strategy : string;
  readiness : string;
  candidate_count : int;
  best_score : float option;
  workload_profile : string;
  stage : string option;
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

let pipeline_json () =
  let metrics =
    Risc_pipeline.aggregate_metrics Tool_risc.global_registry
  in
  Risc_types.metrics_to_yojson metrics

let cache_json () =
  Cache_coherence.aggregate_metrics Tool_risc.global_coherence
  |> Cache_coherence.metrics_to_yojson

let ooo_json () =
  Reservation_station.aggregate_metrics Tool_risc.global_scheduler

let speculative_json () =
  let status = Speculative_engine.status Tool_risc.global_spec_engine in
  U.member "metrics" status

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
    ("avg_candidate_count", `Float avg_candidate_count);
    ("avg_best_score", `Float avg_best_score);
    ("top_stage", match top_stage with Some stage -> `String stage | None -> `Null);
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
  let blocked_ops = get_int_default search_fabric "blocked_operations" 0 in
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
      ("tone", `String (if cache_bus_traffic >= 20 || cache_hit_rate < 0.2 then "bad"
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
      ("tone", `String (tone_of_inverse_threshold ~warn:60.0 ~bad:40.0 avg_best_score));
      ("avg_best_score", `Float avg_best_score);
      ("avg_candidate_count", U.member "avg_candidate_count" search_fabric);
      ("best_first_operations", U.member "best_first_operations" search_fabric);
    ]);
    ("speculative_posture", `Assoc [
      ("tone", `String (if spec_active > 0 && spec_commit_rate < 0.5 then "warn" else "ok"));
      ("active_sessions", `Int spec_active);
      ("commit_rate", `Float spec_commit_rate);
      ("total_speculations", U.member "total_speculations" speculative);
    ]);
  ]

let summary_json ~(search_rows : search_row list) =
  let pipeline = pipeline_json () in
  let cache = cache_json () in
  let ooo = ooo_json () in
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
