include Cp_snapshot_core

let iso_of_unix = Dashboard_utils.iso_of_unix

let file_fingerprint path =
  try
    let stats = Unix.stat path in
    Some (stats.st_mtime, stats.st_ctime, stats.st_size)
  with Unix.Unix_error _ -> None

let file_mtime path =
  match file_fingerprint path with
  | Some (mtime, _, _) -> Some mtime
  | None -> None

type default_trace_cache_entry = {
  cp_events_fingerprint : (float * float * int) option;
  operator_log_fingerprint : (float * float * int) option;
  events : Yojson.Safe.t list;
}

let default_trace_cache :
    ((string * int), default_trace_cache_entry) Hashtbl.t =
  Hashtbl.create 8

let max_default_trace_cache_entries = 16

let evict_default_trace_cache_entry () =
  let victim = ref None in
  Hashtbl.iter (fun key _ ->
      match !victim with
      | Some _ -> ()
      | None -> victim := Some key)
    default_trace_cache;
  match !victim with
  | Some key -> Hashtbl.remove default_trace_cache key
  | None -> ()

let default_trace_cache_key config ~limit =
  (Room.masc_dir config, limit)

let default_trace_cache_fingerprints config =
  ( file_fingerprint (events_path config),
    file_fingerprint (operator_action_log_path config) )

let cached_default_trace_events config ~limit =
  let key = default_trace_cache_key config ~limit in
  let cp_events_fingerprint, operator_log_fingerprint =
    default_trace_cache_fingerprints config
  in
  match Hashtbl.find_opt default_trace_cache key with
  | Some entry
    when entry.cp_events_fingerprint = cp_events_fingerprint
         && entry.operator_log_fingerprint = operator_log_fingerprint ->
      Some entry.events
  | _ -> None

let store_default_trace_events config ~limit ~events =
  let key = default_trace_cache_key config ~limit in
  let cp_events_fingerprint, operator_log_fingerprint =
    default_trace_cache_fingerprints config
  in
  if
    Hashtbl.length default_trace_cache >= max_default_trace_cache_entries
    && not (Hashtbl.mem default_trace_cache key)
  then evict_default_trace_cache_entry ();
  Hashtbl.replace default_trace_cache key
    { cp_events_fingerprint; operator_log_fingerprint; events }

let traces_json_of_events events =
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ("events", `List events);
    ]

let swarm_slot_samples_tail_lines () = 2048

let read_jsonl_tail_json path ~max_lines =
  read_jsonl_tail_lines path ~max_lines
  |> List.filter_map (fun line ->
         let trimmed = String.trim line in
         if trimmed = "" then None
         else
           match Safe_ops.parse_json_safe ~context:path trimmed with
           | Ok json -> Some json
           | Error _ -> None)

let swarm_live_dir config =
  Filename.concat (control_plane_dir config) "swarm-live"

type swarm_live_artifact = {
  run_id : string;
  run_dir : string;
  path : string;
  captured_at : float;
}

type slot_metrics = {
  peak_hot_slots : int option;
  ctx_per_slot : int option;
  captured_at : string option;
}

type runtime_doctor = {
  checked_at : string option;
  provider_base_url : string option;
  provider_reachable : bool option;
  provider_status_code : int option;
  provider_error : string option;
  provider_model_id : string option;
  actual_model_id : string option;
  slot_url : string option;
  slot_reachable : bool option;
  slot_status_code : int option;
  expected_slots : int option;
  actual_slots : int option;
  expected_ctx : int option;
  actual_ctx : int option;
  configured_capacity : int option;
  runtime_blocker : string option;
  detail : string option;
}

let latest_swarm_live_artifact config filename =
  let root = swarm_live_dir config in
  match Safe_ops.list_dir_safe root with
  | Error _ -> None
  | Ok entries ->
      entries
      |> List.filter_map (fun run_id ->
             let run_dir = Filename.concat root run_id in
             if Sys.file_exists run_dir && Sys.is_directory run_dir then
               let path = Filename.concat run_dir filename in
               match file_mtime path with
               | Some captured_at ->
                   Some { run_id; run_dir; path; captured_at }
               | None -> None
             else None)
      |> List.sort (fun (left : swarm_live_artifact) (right : swarm_live_artifact) ->
             Float.compare right.captured_at left.captured_at)
      |> list_hd_opt

let read_slot_metrics_from_json path =
  match Safe_ops.read_json_file_safe path with
  | Error _ -> None
  | Ok json ->
      Some
        {
          peak_hot_slots =
            (match U.member "peak_active_slots" json with
            | `Int value -> Some value
            | `Intlit value -> int_of_string_opt value
            | _ -> None);
          ctx_per_slot =
            (match U.member "ctx_per_slot" json with
            | `Int value -> Some value
            | `Intlit value -> int_of_string_opt value
            | _ -> None);
          captured_at = get_string_opt json "last_sample_at";
        }

let read_slot_metrics_from_samples path =
  let rows =
    (* Fallback path only. Keep reads bounded so an oversized slot-samples
       artifact cannot force command-plane summary refreshes to load the
       entire file into memory. *)
    read_jsonl_tail_json path ~max_lines:(swarm_slot_samples_tail_lines ())
  in
  let peak_hot_slots =
    rows
    |> List.fold_left
         (fun acc row ->
           max acc
             (match U.member "active_slots" row with
             | `Int value -> value
             | `Intlit value -> Option.value ~default:0 (int_of_string_opt value)
             | _ -> 0))
         0
  in
  let ctx_per_slot =
    rows
    |> List.rev
    |> List.find_map (fun row ->
           match U.member "ctx_per_slot" row with
           | `Int value -> Some value
           | `Intlit value -> int_of_string_opt value
           | _ -> None)
  in
  let captured_at =
    rows
    |> List.rev
    |> List.find_map (fun row -> get_string_opt row "timestamp")
  in
  if rows = [] then None
  else Some { peak_hot_slots = Some peak_hot_slots; ctx_per_slot; captured_at }

let read_slot_metrics run_dir =
  let telemetry_path = Filename.concat run_dir "slot-telemetry.json" in
  if Sys.file_exists telemetry_path then
    read_slot_metrics_from_json telemetry_path
  else
    let samples_path = Filename.concat run_dir "slot-samples.jsonl" in
    if Sys.file_exists samples_path then read_slot_metrics_from_samples samples_path
    else None

let read_runtime_doctor_json run_dir =
  let doctor_path = Filename.concat run_dir "runtime-doctor.json" in
  if not (Sys.file_exists doctor_path) then
    None
  else
    match Safe_ops.read_json_file_safe doctor_path with
    | Error _ -> None
    | Ok json ->
        Some
          {
            checked_at = get_string_opt json "checked_at";
            provider_base_url = get_string_opt json "provider_base_url";
            provider_reachable = U.member "provider_reachable" json |> U.to_bool_option;
            provider_status_code = U.member "provider_status_code" json |> U.to_int_option;
            provider_error = get_string_opt json "provider_error";
            provider_model_id = get_string_opt json "provider_model_id";
            actual_model_id = get_string_opt json "actual_model_id";
            slot_url = get_string_opt json "slot_url";
            slot_reachable = U.member "slot_reachable" json |> U.to_bool_option;
            slot_status_code = U.member "slot_status_code" json |> U.to_int_option;
            expected_slots = U.member "expected_slots" json |> U.to_int_option;
            actual_slots = U.member "actual_slots" json |> U.to_int_option;
            expected_ctx = U.member "expected_ctx" json |> U.to_int_option;
            actual_ctx = U.member "actual_ctx" json |> U.to_int_option;
            configured_capacity = U.member "configured_capacity" json |> U.to_int_option;
            runtime_blocker = get_string_opt json "runtime_blocker";
            detail = get_string_opt json "detail";
          }

let swarm_proof_json config =
  let int_member json key =
    match U.member key json with
    | `Int value -> Some value
    | `Intlit value -> int_of_string_opt value
    | _ -> None
  in
  let workers_json
      ?expected ?joined ?current_task_bound ?fresh_heartbeats ?done_workers
      ?final_markers () =
    `Assoc
      [
        ("expected", Json_util.int_opt_to_json expected);
        ("joined", Json_util.int_opt_to_json joined);
        ( "current_task_bound",
          Json_util.int_opt_to_json current_task_bound );
        ( "fresh_heartbeats",
          Json_util.int_opt_to_json fresh_heartbeats );
        ("done", Json_util.int_opt_to_json done_workers);
        ("final", Json_util.int_opt_to_json final_markers);
      ]
  in
  let expected_dir = swarm_live_dir config in
  match latest_swarm_live_artifact config "swarm-live-summary.json" with
  | Some summary_artifact -> (
      match Safe_ops.read_json_file_safe summary_artifact.path with
      | Ok summary_json ->
          let slot_metrics = read_slot_metrics summary_artifact.run_dir in
          let captured_at =
            Option.value
              ~default:(iso_of_unix summary_artifact.captured_at)
              (Option.bind slot_metrics (fun metrics -> metrics.captured_at))
          in
          `Assoc
            [
              ("status", `String "present");
              ("source", `String "artifact");
              ("reason_code", `String "artifact_present");
              ( "status_summary",
                `String
                  "A swarm-live summary artifact was found and parsed successfully." );
              ("run_id", `String summary_artifact.run_id);
              ("captured_at", `String captured_at);
              ( "pass",
                match U.member "pass" summary_json with
                | `Bool value -> `Bool value
                | _ -> `Null );
              ( "peak_hot_slots",
                Json_util.int_opt_to_json (Option.bind slot_metrics (fun metrics -> metrics.peak_hot_slots)) );
              ( "ctx_per_slot",
                Json_util.int_opt_to_json (Option.bind slot_metrics (fun metrics -> metrics.ctx_per_slot)) );
              ( "workers",
                workers_json
                  ?expected:(option_or_else (int_member summary_json "expected_workers")
                               (fun () -> int_member summary_json "worker_count"))
                  ?joined:(int_member summary_json "joined_workers")
                  ?current_task_bound:(int_member summary_json "current_task_bound")
                  ?fresh_heartbeats:(int_member summary_json "fresh_heartbeats")
                  ?done_workers:(int_member summary_json "completed_workers")
                  ?final_markers:(int_member summary_json "final_markers_seen")
                  () );
              ("expected_artifact_dir", `String summary_artifact.run_dir);
              ("artifact_ref", `String summary_artifact.path);
              ("missing_reason", `Null);
            ]
      | Error _ -> `Assoc
          [
            ("status", `String "missing");
            ("source", `String "none");
            ("reason_code", `String "summary_unreadable");
            ( "status_summary",
              `String
                "A swarm-live summary artifact exists, but it could not be read." );
            ("run_id", `Null);
            ("captured_at", `Null);
            ("pass", `Null);
            ("peak_hot_slots", `Null);
            ("ctx_per_slot", `Null);
            ("workers", workers_json ());
            ("expected_artifact_dir", `String summary_artifact.run_dir);
            ("artifact_ref", `Null);
            ( "missing_reason",
              `String
                "Latest swarm-live summary artifact could not be read." );
          ] )
  | None -> (
      match latest_swarm_live_artifact config "slot-samples.jsonl" with
      | Some slot_artifact -> (
          match read_slot_metrics_from_samples slot_artifact.path with
          | Some metrics ->
              `Assoc
                [
                  ("status", `String "fallback");
                  ("source", `String "slot_samples");
                  ("reason_code", `String "slot_samples_only");
                  ( "status_summary",
                    `String
                      "Only slot telemetry was found; worker completion proof is still missing." );
                  ("run_id", `String slot_artifact.run_id);
                  ( "captured_at",
                    match metrics.captured_at with
                    | Some value -> `String value
                    | None -> `String (iso_of_unix slot_artifact.captured_at) );
                  ("pass", `Null);
                  ( "peak_hot_slots",
                    Json_util.int_opt_to_json metrics.peak_hot_slots );
                  ( "ctx_per_slot",
                    Json_util.int_opt_to_json metrics.ctx_per_slot );
                  ("workers", workers_json ());
                  ("expected_artifact_dir", `String slot_artifact.run_dir);
                  ("artifact_ref", `String slot_artifact.path);
                  ( "missing_reason",
                    `String
                      "Only slot samples were found; worker completion proof is unavailable." );
                ]
          | None ->
              `Assoc
                [
                  ("status", `String "missing");
                  ("source", `String "none");
                  ("reason_code", `String "slot_samples_unreadable");
                  ( "status_summary",
                    `String
                      "Slot telemetry exists, but the dashboard could not summarize it." );
                  ("run_id", `Null);
                  ("captured_at", `Null);
                  ("pass", `Null);
                  ("peak_hot_slots", `Null);
                  ("ctx_per_slot", `Null);
                  ("workers", workers_json ());
                  ("expected_artifact_dir", `String slot_artifact.run_dir);
                  ("artifact_ref", `Null);
                  ( "missing_reason",
                    `String
                      "Latest slot sample artifact could not be read." );
                ] )
      | None ->
          `Assoc
            [
              ("status", `String "missing");
              ("source", `String "none");
              ("reason_code", `String "no_swarm_live_artifacts");
              ( "status_summary",
                `String
                  "No swarm-live proof artifacts were found for the current control-plane state." );
              ("run_id", `Null);
              ("captured_at", `Null);
              ("pass", `Null);
              ("peak_hot_slots", `Null);
              ("ctx_per_slot", `Null);
              ("workers", workers_json ());
              ("expected_artifact_dir", `String expected_dir);
              ("artifact_ref", `Null);
              ( "missing_reason",
                `String
                  "No swarm-live proof artifacts were found under .masc/control-plane/swarm-live." );
            ] )

let topology_summary_json_from_state (state : snapshot_state) =
  let summary =
    build_topology_summary ~units:state.units ~managed_units:state.managed_units
      ~agents:state.agents ~operations:state.operations
  in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ("source", `String state.source);
      ("summary", topology_summary_to_json summary);
    ]

let operations_summary_json_from_state (state : snapshot_state) =
  let search_store = read_search_stats state.config in
  let readiness_of_operation (operation : operation_record) =
    let blockers =
      operation.depends_on_operation_ids
      |> List.filter_map (fun dep_id ->
             match operation_by_id state.operations dep_id with
             | Some upstream when upstream.status = Completed -> None
             | Some upstream when Option.is_some upstream.checkpoint_ref -> None
             | Some _upstream ->
                 Some
                   {
                     Cp_microarch_summary.strategy = operation.search_strategy;
                     readiness = "blocked";
                     status = operation.status;
                     candidate_count = 0;
                     best_score = None;
                     workload_profile = operation_workload_profile operation;
                     stage = operation.stage;
                     artifact_scope_count = List.length operation.artifact_scope;
                     artifact_scope_key =
                       (match List.sort_uniq String.compare operation.artifact_scope with
                       | [] -> None
                       | scopes -> Some (String.concat "|" scopes));
                   }
             | None ->
                 Some
                   {
                     Cp_microarch_summary.strategy = operation.search_strategy;
                     readiness = "blocked";
                     status = operation.status;
                     candidate_count = 0;
                     best_score = None;
                     workload_profile = operation_workload_profile operation;
                     stage = operation.stage;
                     artifact_scope_count = List.length operation.artifact_scope;
                     artifact_scope_key =
                       (match List.sort_uniq String.compare operation.artifact_scope with
                       | [] -> None
                       | scopes -> Some (String.concat "|" scopes));
                   })
    in
    if blockers = [] then "ready" else "blocked"
  in
  let search_rows =
    List.map
      (fun (operation : operation_record) ->
        let stats =
          Cp_search_fabric.lookup_stats search_store
            ~unit_id:operation.assigned_unit_id
            ~workload_profile:(operation_workload_profile operation)
            ~stage:(operation_stage_key operation)
        in
        {
          Cp_microarch_summary.strategy = operation.search_strategy;
          readiness = readiness_of_operation operation;
          status = operation.status;
          candidate_count =
            (match operation_search_strategy operation with
            | Cp_search_fabric.Best_first_v1 -> 1
            | Cp_search_fabric.Legacy -> 0);
          best_score =
            (match operation_search_strategy operation with
            | Cp_search_fabric.Best_first_v1 ->
                Some (Cp_search_fabric.posterior_mean stats *. 100.0)
            | Cp_search_fabric.Legacy -> None);
          workload_profile = operation_workload_profile operation;
          stage = operation.stage;
          artifact_scope_count = List.length operation.artifact_scope;
          artifact_scope_key =
            (match List.sort_uniq String.compare operation.artifact_scope with
            | [] -> None
            | scopes -> Some (String.concat "|" scopes));
        })
      state.operations
  in
  let managed_count =
    List.length
      (List.filter
         (fun (operation : operation_record) -> operation.source = "managed")
         state.operations)
  in
  let op_counts = count_operation_statuses state.operations in
  let recent_active =
    state.operations
    |> List.filter (fun (op : operation_record) -> active_operation_status op.status)
    |> List.sort (fun (a : operation_record) (b : operation_record) ->
           compare b.updated_at a.updated_at)
    |> (fun ops -> if List.length ops > 10 then List.filteri (fun i _ -> i < 10) ops else ops)
    |> List.map (fun (op : operation_record) ->
           `Assoc
             [
               ("operation_id", `String op.operation_id);
               ("objective", `String op.objective);
               ("status", `String (string_of_operation_status op.status));
               ("assigned_unit_id", `String op.assigned_unit_id);
               ("updated_at", `String op.updated_at);
             ])
  in
  let microarch = Cp_microarch_summary.summary_json
    ~pending_ops:(op_counts.planned_count + op_counts.paused_count)
    ~in_flight_ops:op_counts.active_count
    ~stalled_count:op_counts.failed_count
    ~search_rows () in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ( "summary",
        `Assoc
          [
            ("total", `Int (List.length state.operations));
            ("active", `Int op_counts.active_count);
            ("planned", `Int op_counts.planned_count);
            ("paused", `Int op_counts.paused_count);
            ("completed", `Int op_counts.completed_count);
            ("failed", `Int op_counts.failed_count);
            ("cancelled", `Int op_counts.cancelled_count);
            ("managed", `Int managed_count);
            ("projected", `Int (List.length state.operations - managed_count));
          ] );
      ("recent_active", `List recent_active);
      ("microarch", microarch);
    ]

let detachments_summary_json_from_state (state : snapshot_state) =
  let projected_count =
    List.length
      (List.filter
         (fun (detachment : detachment_record) -> detachment.source <> "managed")
         state.detachments)
  in
  let count_status (status : detachment_status) =
    List.length
      (List.filter
         (fun (detachment : detachment_record) ->
           detachment.status = status)
         state.detachments)
  in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ( "summary",
        `Assoc
          [
            ("total", `Int (List.length state.detachments));
            ("active", `Int (count_status Det_active));
            ("awaiting_approval", `Int (count_status Det_awaiting_approval));
            ("stalled", `Int (count_status Det_stalled));
            ("projected", `Int projected_count);
          ] );
    ]

let intents_summary_json_from_state (state : snapshot_state) =
  let count_state target =
    state.intents
    |> List.filter (fun (intent : intent_record) -> intent.state = target)
    |> List.length
  in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ( "summary",
        `Assoc
          [
            ("total", `Int (List.length state.intents));
            ("active", `Int (count_state Active_intent));
            ("blocked", `Int (count_state Blocked_intent));
            ("handoff_ready", `Int (count_state Handoff_ready));
          ] );
      ("intents", `List (List.map intent_to_json state.intents));
    ]

let summary_json config =
  let state = build_snapshot_state config in
  let alerts =
    list_alerts_json_from_state config state
    |> U.member "summary"
  in
  let decisions =
    list_policy_decisions_json_from_state state
    |> U.member "summary"
  in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ("topology", topology_summary_json_from_state state);
      ("intents", intents_summary_json_from_state state);
      ("operations", operations_summary_json_from_state state);
      ("detachments", detachments_summary_json_from_state state);
      ("alerts", `Assoc [ ("summary", alerts) ]);
      ("decisions", `Assoc [ ("summary", decisions) ]);
      ("swarm_proof", swarm_proof_json config);
    ]

let recent_execution_session_trace_events _config _session_id _limit =
  (* Team_session_store removed — return empty *)
  []

let recent_operator_trace_events config ?trace_id limit =
  if not (Room_utils.path_exists config (operator_action_log_path config)) then
    []
  else
    (match trace_id with
     | None ->
         (* Overfetch 3x to compensate for lines lost to JSON parse
            failures, blank lines, or filter exclusions (#2945). *)
         read_jsonl_tail_lines (operator_action_log_path config)
           ~max_lines:(limit * 3)
     | Some _ ->
         (* Tail-bounded read to avoid stalling on large operator logs (#4250).
            Overfetch 5x to increase hit rate for trace_id filtering. *)
         read_jsonl_tail_lines (operator_action_log_path config)
           ~max_lines:(limit * 5))
    |> List.filter_map (fun line ->
           let trimmed = String.trim line in
           if trimmed = "" then None
           else
             match Safe_ops.parse_json_safe ~context:"command_plane_v2.operator_log" trimmed with
             | Ok (`Assoc _ as row) ->
                 let row_trace_id = get_string_opt row "trace_id" in
                 let keep =
                   match trace_id, row_trace_id with
                   | None, _ -> true
                   | Some expected, Some actual -> String.equal expected actual
                   | Some _, None -> false
                 in
                 if keep then
                   Some
                     (`Assoc
                       [
                         ("event_id", `String (next_event_id "trace"));
                         ("trace_id", `String (get_string_default row "trace_id" "operator"));
                         ("event_type", `String (get_string_default row "action_type" "operator_action"));
                         ("operation_id", `Null);
                         ("unit_id", `Null);
                         ("actor", Json_util.string_opt_to_json (get_string_opt row "actor"));
                         ("source", `String "operator");
                         ("timestamp", `String (get_string_default row "created_at" (Types.now_iso ())));
                         ("detail", row);
                       ])
                 else
                   None
             | Ok _ | Error _ -> None)
    |> (fun events ->
         let rev = List.rev events in
         let limited = List.filteri (fun idx _ -> idx < limit) rev in
         List.rev limited)

let recent_swarm_trace_events config limit =
  if not (Room_utils.path_exists config (swarm_path config)) then
    []
  else
    match Room_utils.read_json_opt config (swarm_path config) with
    | Some (`Assoc _ as root) ->
        let config_json =
          match U.member "config" root with `Assoc _ as value -> value | _ -> `Assoc []
        in
        let swarm_id = get_string_default config_json "id" "swarm-runtime" in
        let generation = get_int_default root "generation" 0 in
        let timestamp =
          match U.member "last_evolution" root with
          | `Float value -> iso_of_unix value
          | `Int value -> iso_of_unix (float_of_int value)
          | _ -> Types.now_iso ()
        in
        [
          `Assoc
            [
              ("event_id", `String (next_event_id "trace"));
              ("trace_id", `String ("swarm-trace-" ^ safe_slug swarm_id));
              ("event_type", `String "swarm_projected");
              ("operation_id", `String ("swarm-" ^ safe_slug swarm_id));
              ("unit_id", `Null);
              ("actor", `String "swarm");
              ("source", `String "swarm");
              ("timestamp", `String timestamp);
              ("detail", `Assoc [ ("generation", `Int generation); ("config", config_json) ]);
            ];
        ]
        |> List.filteri (fun idx _ -> idx < limit)
    | _ -> []

let build_default_trace_events config ~limit =
  let events =
    read_recent_events config ~limit:(max limit 50)
  in
  let cp_events =
    events
    |> List.rev
    |> List.filteri (fun idx _ -> idx < limit)
    |> List.rev
    |> List.map (fun (event : event_record) ->
           `Assoc
             [
               ("event_id", `String event.event_id);
               ("trace_id", `String event.trace_id);
               ("event_type", `String event.event_type);
               ("operation_id", Json_util.string_opt_to_json event.operation_id);
               ("unit_id", Json_util.string_opt_to_json event.unit_id);
               ("actor", Json_util.string_opt_to_json event.actor);
               ("source", `String event.source);
               ("timestamp", `String event.ts);
               ("detail", event.detail);
             ])
  in
  let operator_events = recent_operator_trace_events config limit in
  cp_events @ operator_events

let list_traces_json config ?operation_id ?(limit = 25) () =
  match operation_id with
  | None ->
      let events =
        match cached_default_trace_events config ~limit with
        | Some events -> events
        | None ->
            let events = build_default_trace_events config ~limit in
            store_default_trace_events config ~limit ~events;
            events
      in
      traces_json_of_events events
  | Some operation_ref ->
      let events =
        read_events ~max_lines:(limit * 3) config
        |> List.filter (fun (event : event_record) ->
               (match event.operation_id with
               | Some value -> String.equal value operation_ref
               | None -> false)
               || String.equal event.trace_id operation_ref)
      in
      let cp_events =
        events
        |> List.rev
        |> List.filteri (fun idx _ -> idx < limit)
        |> List.rev
        |> List.map (fun (event : event_record) ->
               `Assoc
                 [
                   ("event_id", `String event.event_id);
                   ("trace_id", `String event.trace_id);
                   ("event_type", `String event.event_type);
                   ("operation_id", Json_util.string_opt_to_json event.operation_id);
                   ("unit_id", Json_util.string_opt_to_json event.unit_id);
                   ("actor", Json_util.string_opt_to_json event.actor);
                   ("source", `String event.source);
                   ("timestamp", `String event.ts);
                   ("detail", event.detail);
                 ])
      in
      let execution_session_events =
        let _, _, units, _ = topology_units config in
        let operations = all_operations config units in
        match
          operations
          |> List.find_opt (fun (operation : operation_record) ->
                 String.equal operation.operation_id operation_ref
                 || String.equal operation.trace_id operation_ref)
        with
        | Some operation -> (
            match operation.detachment_session_id with
            | Some session_id -> recent_execution_session_trace_events config session_id limit
            | None -> [])
        | None -> []
      in
      let operator_events =
        recent_operator_trace_events config ~trace_id:operation_ref limit
      in
      traces_json_of_events (cp_events @ execution_session_events @ operator_events)
