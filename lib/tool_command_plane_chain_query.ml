open Tool_command_plane_support
open Tool_command_plane_chain_common

let history_timestamp_iso json =
  match U.member "timestamp" json with
  | `String value -> Some value
  | `Float value -> Some (Command_plane_v2.iso_of_unix value)
  | `Int value -> Some (Command_plane_v2.iso_of_unix (float_of_int value))
  | `Intlit value -> (try Some (Command_plane_v2.iso_of_unix (float_of_string value)) with Failure _ -> None)
  | _ -> None

let history_tokens json =
  match U.member "tokens" json with
  | `Int value -> Some value
  | `Intlit value -> (try Some (int_of_string value) with Failure _ -> None)
  | `Assoc fields -> (
      match List.assoc_opt "total_tokens" fields with
      | Some (`Int value) -> Some value
      | Some (`Intlit value) -> (try Some (int_of_string value) with Failure _ -> None)
      | _ ->
          let prompt =
            match List.assoc_opt "prompt_tokens" fields with
            | Some (`Int value) -> value
            | Some (`Intlit value) -> (try int_of_string value with Failure _ -> 0)
            | _ -> 0
          in
          let completion =
            match List.assoc_opt "completion_tokens" fields with
            | Some (`Int value) -> value
            | Some (`Intlit value) -> (try int_of_string value with Failure _ -> 0)
            | _ -> 0
          in
          if prompt + completion > 0 then Some (prompt + completion) else None)
  | _ -> None

let history_event_json json =
  `Assoc
    [
      ( "event",
        match U.member "event" json with
        | `String value -> `String value
        | _ -> `String "unknown" );
      ( "chain_id",
        match U.member "chain_id" json with
        | `String value -> `String value
        | _ -> `Null );
      ( "timestamp",
        match history_timestamp_iso json with Some value -> `String value | None -> `Null );
      ( "duration_ms",
        match U.member "duration_ms" json with
        | `Int value -> `Int value
        | `Intlit value -> (try `Int (int_of_string value) with Failure _ -> `Null)
        | _ -> `Null );
      ("message", match U.member "message" json with `String value -> `String value | _ -> `Null);
      ("tokens", match history_tokens json with Some value -> `Int value | None -> `Null);
    ]

let run_store_history_json run_json =
  let chain_id =
    match U.member "chain_id" run_json with
    | `String value -> `String value
    | _ -> `Null
  in
  let duration_ms =
    match U.member "duration_ms" run_json with
    | `Int value -> `Int value
    | `Intlit value -> (try `Int (int_of_string value) with Failure _ -> `Null)
    | _ -> `Null
  in
  let started_at =
    match U.member "started_at" run_json with
    | `Float value -> Some value
    | `Int value -> Some (float_of_int value)
    | `Intlit value -> (try Some (float_of_string value) with Failure _ -> None)
    | _ -> None
  in
  let completed_at =
    match started_at, duration_ms with
    | Some started, `Int duration ->
        Some (Command_plane_v2.iso_of_unix (started +. (float_of_int duration /. 1000.0)))
    | Some started, _ -> Some (Command_plane_v2.iso_of_unix started)
    | None, _ -> None
  in
  let event_name =
    match U.member "success" run_json with
    | `Bool true -> "chain_complete"
    | `Bool false -> "chain_failed"
    | _ -> "chain_complete"
  in
  `Assoc
    [
      ("event", `String event_name);
      ("chain_id", chain_id);
      ( "timestamp",
        match completed_at with Some value -> `String value | None -> `Null );
      ("duration_ms", duration_ms);
      ("message", `Null);
      ("tokens", `Null);
    ]

let legacy_history_event_for_operation
    (operation : Command_plane_v2.operation_record)
    (chain : Command_plane_v2.chain_record) =
  let event =
    if String.equal chain.status "failed" || operation.status = Command_plane_v2.Failed then
      "chain_failed"
    else "chain_complete"
  in
  fallback_history_event_json ~event ~chain_id:chain.chain_id
    ?timestamp:(Some operation.updated_at) ()

let backfill_chain_overlays config =
  let actor = "system/chain-backfill" in
  Command_plane_v2.read_operations config
  |> List.iter (fun (operation : Command_plane_v2.operation_record) ->
         match operation.chain with
         | None -> ()
         | Some chain ->
             let run_json_opt =
               match chain.run_id with
               | Some run_id -> Chain_native_eio.run_json ~run_id
               | None -> None
             in
             let next_history_event =
               match chain.history_event with
               | Some _ as existing -> existing
               | None -> (
                   match run_json_opt with
                   | Some run_json -> Some (run_store_history_json run_json)
                   | None
                     when String.equal chain.status "completed"
                          || String.equal chain.status "failed" ->
                       Some (legacy_history_event_for_operation operation chain)
                   | None -> None)
             in
             let next_mermaid =
               match chain.mermaid with
               | Some _ as existing -> existing
               | None -> (
                   match mermaid_from_run_json run_json_opt with
                   | Some _ as value -> value
                   | None -> (
                       match chain.chain_id with
                       | Some chain_id ->
                           Chain_native_eio.registered_chain_mermaid ~config ~chain_id
                       | None -> None))
             in
             let next_preview_run =
               match chain.preview_run with
               | Some _ as existing -> existing
               | None -> (
                   match run_json_opt with
                   | Some run_json -> Some run_json
                   | None -> (
                       match chain.chain_id, next_mermaid with
                       | Some chain_id, _ ->
                           preview_run_json_of_source ~config ~chain_id ()
                       | None, Some mermaid ->
                           preview_run_json_of_source ~config ~mermaid ()
                       | None, None -> None))
             in
             let next_checkpoint_ref =
               match operation.checkpoint_ref, chain.run_id with
               | Some _ as current, _ -> current
               | None, Some run_id -> Some run_id
               | None, None -> None
             in
             if next_history_event <> chain.history_event
                || next_mermaid <> chain.mermaid
                || next_preview_run <> chain.preview_run
                || next_checkpoint_ref <> operation.checkpoint_ref
             then
               ignore
                 (Command_plane_v2.update_operation config ~actor
                    ~operation_id:operation.operation_id
                    ~event_type:"chain_backfilled"
                    ~detail:
                      (`Assoc
                        [
                          ("history_event", `Bool (next_history_event <> chain.history_event));
                          ("mermaid", `Bool (next_mermaid <> chain.mermaid));
                          ("preview_run", `Bool (next_preview_run <> chain.preview_run));
                          ("checkpoint_ref", `Bool (next_checkpoint_ref <> operation.checkpoint_ref));
                        ])
                    (fun current ->
                      let updated_chain =
                        match current.chain with
                        | Some current_chain ->
                            {
                              current_chain with
                              history_event = next_history_event;
                              mermaid = next_mermaid;
                              preview_run = next_preview_run;
                            }
                        | None ->
                            {
                              chain with
                              history_event = next_history_event;
                              mermaid = next_mermaid;
                              preview_run = next_preview_run;
                            }
                      in
                      { current with chain = Some updated_chain; checkpoint_ref = next_checkpoint_ref })))

let chain_summary_json (ctx : (_, _) context) =
  let backend = chain_backend () in
  let backend_name = chain_backend_to_string backend in
  let build_summary ~connection ~status_rows ~recent_history =
    let running_index : (string, Yojson.Safe.t) Hashtbl.t = Hashtbl.create 16 in
    List.iter
      (fun row ->
        match U.member "chain_id" row with
        | `String chain_id -> Hashtbl.replace running_index chain_id row
        | _ -> ())
      status_rows;
    let mermaid_index : (string, string) Hashtbl.t = Hashtbl.create 16 in
    let latest_history : (string, Yojson.Safe.t) Hashtbl.t = Hashtbl.create 16 in
    List.iter
      (fun row ->
        match U.member "chain_id" row with
        | `String chain_id ->
            if not (Hashtbl.mem latest_history chain_id) then
              Hashtbl.replace latest_history chain_id row;
            (match U.member "event" row, U.member "mermaid_dsl" row with
            | `String "chain_start", `String mermaid
              when not (Hashtbl.mem mermaid_index chain_id) ->
                Hashtbl.replace mermaid_index chain_id mermaid
            | _ -> ())
        | _ -> ())
      recent_history;
    let linked_operations =
      Command_plane_v2.read_operations ctx.config
      |> List.filter (fun (operation : Command_plane_v2.operation_record) ->
             Option.is_some operation.chain)
    in
    let overlays =
      linked_operations
      |> List.map (fun (operation : Command_plane_v2.operation_record) ->
             let persisted_history_json =
               match operation.chain with
               | Some chain -> Option.value ~default:`Null chain.history_event
               | None -> `Null
             in
             let persisted_mermaid_json =
               match operation.chain with
               | Some chain ->
                   Option.fold ~none:`Null ~some:(fun value -> `String value) chain.mermaid
               | None -> `Null
             in
             let persisted_preview_json =
               match operation.chain with
               | Some chain -> Option.value ~default:`Null chain.preview_run
               | None -> `Null
             in
             let run_json_opt =
               match operation.chain with
               | Some chain -> (
                   match chain.run_id with
                   | Some run_id -> Chain_native_eio.run_json ~run_id
                   | None -> None)
               | None -> None
             in
             let runtime_json =
               match operation.chain with
               | Some chain
                 when String.equal chain.status "running" || String.equal chain.status "pending" -> (
                   match chain.chain_id with
                   | Some chain_id ->
                       Hashtbl.find_opt running_index chain_id
                       |> Option.value ~default:`Null
                   | None -> `Null)
               | _ -> `Null
             in
             let history_json =
               match run_json_opt with
               | Some run_json -> run_store_history_json run_json
               | None when persisted_history_json <> `Null -> persisted_history_json
               | None -> (
                   match operation.chain with
                   | Some chain
                     when String.equal chain.status "running" || String.equal chain.status "pending" -> (
                       match chain.chain_id with
                       | Some chain_id ->
                           Hashtbl.find_opt latest_history chain_id
                           |> Option.map history_event_json |> Option.value ~default:`Null
                       | None -> `Null)
                   | _ -> `Null)
             in
             let mermaid_from_run =
               match run_json_opt with
               | Some run_json -> (
                   match U.member "mermaid" run_json with
                   | `String value -> Some value
                   | _ -> None)
               | None -> None
             in
             let mermaid_json =
               match mermaid_from_run with
               | Some value -> `String value
               | None when persisted_mermaid_json <> `Null -> persisted_mermaid_json
               | None -> (
                   match operation.chain with
                   | Some chain
                     when String.equal chain.status "running" || String.equal chain.status "pending" -> (
                       match chain.chain_id with
                       | Some chain_id ->
                           Hashtbl.find_opt mermaid_index chain_id
                           |> Option.map (fun value -> `String value)
                           |> Option.value ~default:`Null
                       | None -> `Null)
                   | _ -> `Null)
             in
             let preview_json =
               match run_json_opt with
               | Some run_json -> run_json
               | None when persisted_preview_json <> `Null -> persisted_preview_json
               | None -> `Null
             in
             `Assoc
               [
                 ("operation", Command_plane_v2.operation_to_json operation);
                 ("runtime", runtime_json);
                 ("history", history_json);
                 ("mermaid", mermaid_json);
                 ("preview_run", preview_json);
               ])
    in
    let recent_failures =
      recent_history
      |> List.filter (fun row ->
             match U.member "event" row with
             | `String "chain_error" -> true
             | _ -> false)
      |> List.length
    in
    let last_history_event_at =
      match recent_history with
      | head :: _ -> history_timestamp_iso head
      | [] -> None
    in
    Ok
      (`Assoc
        [
          ("schema_version", `Int 1);
          ("version", `String "chain-plane-v1");
          ("backend", `String backend_name);
          ("generated_at", `String (Types.now_iso ()));
          ("connection", connection);
          ( "summary",
            `Assoc
              [
                ("linked_operations", `Int (List.length linked_operations));
                ("active_chains", `Int (List.length status_rows));
                ( "running_operations",
                  `Int
                    (List.length
                       (List.filter
                          (fun (operation : Command_plane_v2.operation_record) ->
                            match operation.chain with
                            | Some chain -> String.equal chain.status "running"
                            | None -> false)
                          linked_operations)) );
                ("recent_failures", `Int recent_failures);
                ( "last_history_event_at",
                  match last_history_event_at with
                  | Some value -> `String value
                  | None -> `Null );
              ] );
          ("operations", `List overlays);
          ("recent_history", `List (List.map history_event_json recent_history));
        ])
  in
  let connection =
    `Assoc
      [
        ("status", `String "connected");
        ("base_url", `String "native://masc");
        ("message", `String "Chain summary is served from the native MASC chain plane.");
        ("backend", `String backend_name);
      ]
  in
  build_summary ~connection ~status_rows:(Chain_native_eio.running_chains_json ())
    ~recent_history:(Chain_native_eio.read_history_events ~limit:100)

let chain_run_get_json (_ctx : (_, _) context) ~run_id =
  match validate_run_id run_id with
  | Error _ as err -> err
  | Ok run_id -> (
      match Chain_native_eio.run_json ~run_id with
      | Some json ->
          Ok
            (`Assoc
              [
                ("schema_version", `Int 1);
                ("version", `String "chain-run-v1");
                ("backend", `String "native");
                ("run", json);
              ])
      | None -> Error (Printf.sprintf "chain run not found: %s" run_id))

let handle_chain_snapshot (ctx : (_, _) context) : result =
  json_result (chain_summary_json ctx)

let handle_chain_run_get (ctx : (_, _) context) args : result =
  match get_string_opt args "run_id" with
  | Some run_id -> json_result (chain_run_get_json ctx ~run_id)
  | None -> (false, json_error "run_id is required")

let handle_operation_status (ctx : (_, _) context) args : result =
  let operation_id = get_string_opt args "operation_id" in
  ( true,
    Yojson.Safe.to_string
      (Command_plane_v2.operation_status_json ctx.config ?operation_id ()) )

let handle_intent_create (ctx : (_, _) context) args : result =
  (match Command_plane_v2.create_intent_json ctx.config ~actor:ctx.agent_name args with
  | Ok intent -> (true, json_ok [ ("result", Command_plane_v2.intent_to_json intent) ])
  | Error message -> (false, json_error message))

let handle_intent_status (ctx : (_, _) context) args : result =
  let intent_id = get_string_opt args "intent_id" in
  (true, Yojson.Safe.to_string (Command_plane_v2.list_intents_json ?intent_id ctx.config))

let handle_intent_update (ctx : (_, _) context) args : result =
  (match Command_plane_v2.update_intent_json ctx.config ~actor:ctx.agent_name args with
  | Ok intent -> (true, json_ok [ ("result", Command_plane_v2.intent_to_json intent) ])
  | Error message -> (false, json_error message))

let handle_intent_forecast (ctx : (_, _) context) args : result =
  let intent_id =
    match get_string_opt args "intent_id" with
    | Some value -> value
    | None -> invalid_arg "intent_id is required"
  in
  let limit =
    match Yojson.Safe.Util.member "limit" args with
    | `Int value -> value
    | _ -> 3
  in
  json_result (Command_plane_v2.intent_forecast_json ctx.config intent_id ~limit ())

let handle_operation_checkpoint (ctx : (_, _) context) args : result =
  try
    match Command_plane_v2.checkpoint_operation ctx.config ~actor:ctx.agent_name args with
    | Ok operation ->
        ( true,
          json_ok
            [
              ("result", Command_plane_v2.operation_to_json operation);
              ("traces", Command_plane_v2.list_traces_json ctx.config ~operation_id:operation.operation_id ());
            ] )
    | Error message -> (false, json_error message)
  with Invalid_argument message -> (false, json_error message)

let handle_observe_topology (ctx : (_, _) context) : result =
  (true, Yojson.Safe.to_string (Command_plane_v2.topology_json ctx.config))

let handle_observe_alerts (ctx : (_, _) context) : result =
  (true, Yojson.Safe.to_string (Command_plane_v2.list_alerts_json ctx.config))

let handle_observe_operations (ctx : (_, _) context) : result =
  (true, Yojson.Safe.to_string (Command_plane_v2.observe_operations_json ctx.config))

let int_member_opt json key =
  match U.member key json with
  | `Int value -> Some value
  | `Intlit value -> int_of_string_opt value
  | `Float value -> Some (int_of_float value)
  | _ -> None

let bool_member_opt json key =
  match U.member key json with
  | `Bool value -> Some value
  | _ -> None

let string_member_opt json key =
  match U.member key json with
  | `String value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let string_json value =
  match value with
  | Some v -> `String v
  | None -> `Null

let int_json value =
  match value with
  | Some v -> `Int v
  | None -> `Null

let bool_json value =
  match value with
  | Some v -> `Bool v
  | None -> `Null

let first_some options =
  let rec loop = function
    | [] -> None
    | Some value :: _ -> Some value
    | None :: rest -> loop rest
  in
  loop options

let option_map2 f left right =
  match left, right with
  | Some l, Some r -> Some (f l r)
  | _ -> None

let latest_swarm_run_id config =
  match U.member "run_id" (Cp_snapshot_summaries.swarm_proof_json config) with
  | `String value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let provider_json_of_artifacts runtime_doctor slot_telemetry =
  let timeline =
    match slot_telemetry with
    | Some json -> (
        match U.member "timeline" json with
        | `List _ as value -> value
        | _ -> `List [])
    | None -> `List []
  in
  let field_from_doctor key =
    match runtime_doctor with
    | Some json -> U.member key json
    | None -> `Null
  in
  let field_from_slot key =
    match slot_telemetry with
    | Some json -> U.member key json
    | None -> `Null
  in
  `Assoc
    [
      ("slot_url", field_from_doctor "slot_url");
      ("provider_base_url", field_from_doctor "provider_base_url");
      ("provider_reachable", field_from_doctor "provider_reachable");
      ("provider_status_code", field_from_doctor "provider_status_code");
      ("provider_model_id", field_from_doctor "provider_model_id");
      ("actual_model_id", field_from_doctor "actual_model_id");
      ("expected_slots", field_from_doctor "expected_slots");
      ("actual_slots", field_from_doctor "actual_slots");
      ("expected_ctx", field_from_doctor "expected_ctx");
      ("actual_ctx", field_from_doctor "actual_ctx");
      ("configured_capacity", field_from_doctor "configured_capacity");
      ("slot_reachable", field_from_doctor "slot_reachable");
      ("slot_status_code", field_from_doctor "slot_status_code");
      ("runtime_blocker", field_from_doctor "runtime_blocker");
      ("detail", field_from_doctor "detail");
      ("checked_at", field_from_doctor "checked_at");
      ("total_slots", field_from_slot "total_slots");
      ("ctx_per_slot", field_from_slot "ctx_per_slot");
      ("active_slots_now", field_from_slot "active_slots_now");
      ("peak_active_slots", field_from_slot "peak_active_slots");
      ("sample_count", field_from_slot "sample_count");
      ("last_sample_at", field_from_slot "last_sample_at");
      ("timeline", timeline);
    ]

let summary_json_of_artifacts summary_json slot_telemetry =
  let peak_hot_slots =
    first_some
      [
        Option.bind slot_telemetry (fun json -> int_member_opt json "peak_active_slots");
        int_member_opt summary_json "peak_hot_slots";
      ]
  in
  let expected_workers =
    first_some
      [
        int_member_opt summary_json "expected_workers";
        int_member_opt summary_json "worker_count";
      ]
  in
  let completed_workers = int_member_opt summary_json "completed_workers" in
  let joined_workers =
    first_some
      [
        int_member_opt summary_json "joined_workers";
        completed_workers;
      ]
  in
  let current_task_bound =
    first_some
      [
        int_member_opt summary_json "current_task_bound";
        completed_workers;
      ]
  in
  let fresh_heartbeats =
    first_some
      [
        int_member_opt summary_json "fresh_heartbeats";
        completed_workers;
      ]
  in
  let live_workers =
    first_some
      [
        int_member_opt summary_json "live_workers";
        completed_workers;
      ]
  in
  let final_markers_seen =
    first_some
      [
        int_member_opt summary_json "final_markers_seen";
        completed_workers;
      ]
  in
  let pass_end_to_end =
    first_some
      [
        bool_member_opt summary_json "pass_end_to_end";
        option_map2
          (fun expected completed -> expected > 0 && completed >= expected)
          expected_workers completed_workers;
      ]
  in
  let pass_hot_concurrency =
    first_some
      [
        bool_member_opt summary_json "pass_hot_concurrency";
        Option.map (fun peak -> peak >= 1) peak_hot_slots;
      ]
  in
  let pass =
    first_some
      [
        bool_member_opt summary_json "pass";
        option_map2 ( && ) pass_hot_concurrency pass_end_to_end;
      ]
  in
  `Assoc
    [
      ("expected_workers", int_json expected_workers);
      ("joined_workers", int_json joined_workers);
      ("live_workers", int_json live_workers);
      ("current_task_bound", int_json current_task_bound);
      ("fresh_heartbeats", int_json fresh_heartbeats);
      ("completed_workers", int_json completed_workers);
      ("final_markers_seen", int_json final_markers_seen);
      ("peak_hot_slots", int_json peak_hot_slots);
      ("pass_hot_concurrency", bool_json pass_hot_concurrency);
      ("pass_end_to_end", bool_json pass_end_to_end);
      ("pass", bool_json pass);
    ]

let blocker_json ~code ~detail =
  `Assoc
    [
      ("code", `String code);
      ("severity", `String "bad");
      ("title", `String code);
      ("detail", `String detail);
      ("next_tool", `String "masc_runtime_verify");
    ]

let handle_observe_swarm (ctx : (_, _) context) args : result =
  let run_id =
    match get_string_opt args "run_id" with
    | Some value -> Some value
    | None -> latest_swarm_run_id ctx.config
  in
  let operation_id = get_string_opt args "operation_id" in
  match run_id with
  | None ->
      ( true,
        Yojson.Safe.to_string
          (`Assoc
            [
              ("version", `String "cp-v2");
              ("generated_at", `String (Types.now_iso ()));
              ("run_id", `Null);
              ("room_id", string_json (Room.read_current_room ctx.config));
              ("operation_id", string_json operation_id);
              ("recommended_next_tool", `String "masc_runtime_verify");
              ( "summary",
                `Assoc
                  [
                    ("expected_workers", `Null);
                    ("joined_workers", `Null);
                    ("live_workers", `Null);
                    ("current_task_bound", `Null);
                    ("fresh_heartbeats", `Null);
                    ("completed_workers", `Null);
                    ("final_markers_seen", `Null);
                    ("peak_hot_slots", `Null);
                    ("pass_hot_concurrency", `Null);
                    ("pass_end_to_end", `Null);
                    ("pass", `Null);
                  ] );
              ("provider", `Assoc []);
              ( "blockers",
                `List
                  [
                    blocker_json ~code:"no_swarm_live_artifacts"
                      ~detail:
                        "No swarm-live run id could be resolved from arguments or artifacts.";
                  ] );
              ( "truth_notes",
                `List
                  [
                    `String
                      "swarm-live response is derived from persisted swarm-live artifacts when available.";
                  ] );
            ] ) )
  | Some run_id ->
      let summary_json =
        Cp_paths.find_swarm_live_artifact_json ctx.config run_id "swarm-live-summary.json"
      in
      let runtime_doctor =
        Cp_paths.find_swarm_live_artifact_json ctx.config run_id "runtime-doctor.json"
      in
      let slot_telemetry =
        Cp_paths.find_swarm_live_artifact_json ctx.config run_id "slot-telemetry.json"
      in
      let summary =
        match summary_json with
        | Some json -> summary_json_of_artifacts json slot_telemetry
        | None ->
            `Assoc
              [
                ("expected_workers", `Null);
                ("joined_workers", `Null);
                ("live_workers", `Null);
                ("current_task_bound", `Null);
                ("fresh_heartbeats", `Null);
                ("completed_workers", `Null);
                ("final_markers_seen", `Null);
                ("peak_hot_slots", `Null);
                ("pass_hot_concurrency", `Null);
                ("pass_end_to_end", `Null);
                ("pass", `Null);
              ]
      in
      let provider = provider_json_of_artifacts runtime_doctor slot_telemetry in
      let recommended_next_tool, blockers =
        match runtime_doctor, summary_json with
        | Some doctor, _ -> (
            match string_member_opt doctor "runtime_blocker" with
            | Some blocker ->
                let detail =
                  Option.value ~default:blocker (string_member_opt doctor "detail")
                in
                ("masc_runtime_verify", [ blocker_json ~code:blocker ~detail ])
            | None -> (
                match summary_json with
                | Some summary_artifact -> (
                    match bool_member_opt summary_artifact "pass" with
                    | Some true -> ("masc_observe_traces", [])
                    | _ ->
                        let detail =
                          Option.value ~default:"swarm-live proof did not pass"
                            (string_member_opt summary_artifact "detail")
                        in
                        ( "masc_observe_traces",
                          [ blocker_json ~code:"swarm_proof_failed" ~detail ] ))
                | None ->
                    ( "masc_runtime_verify",
                      [
                        blocker_json ~code:"missing_summary_artifact"
                          ~detail:
                            "swarm-live-summary.json is missing for the requested run_id.";
                      ] )))
        | None, Some summary_artifact -> (
            match bool_member_opt summary_artifact "pass" with
            | Some true -> ("masc_observe_traces", [])
            | _ ->
                let detail =
                  Option.value ~default:"swarm-live proof did not pass"
                    (string_member_opt summary_artifact "detail")
                in
                ( "masc_observe_traces",
                  [ blocker_json ~code:"swarm_proof_failed" ~detail ] ))
        | None, None ->
            ( "masc_runtime_verify",
              [
                blocker_json ~code:"missing_summary_artifact"
                  ~detail:
                    "swarm-live-summary.json is missing for the requested run_id.";
              ] )
      in
      ( true,
        Yojson.Safe.to_string
          (`Assoc
            [
              ("version", `String "cp-v2");
              ("generated_at", `String (Types.now_iso ()));
              ("run_id", `String run_id);
              ("room_id", string_json (Room.read_current_room ctx.config));
              ("operation_id", string_json operation_id);
              ("recommended_next_tool", `String recommended_next_tool);
              ("summary", summary);
              ("provider", provider);
              ("blockers", `List blockers);
              ( "truth_notes",
                `List
                  [
                    `String
                      "swarm-live response is derived from persisted swarm-live artifacts and runtime doctor files.";
                    `String
                      "When live worker evidence is absent, this surface falls back to artifact truth instead of rebuilding state synchronously.";
                  ] );
            ] ) )

let handle_observe_capacity (ctx : (_, _) context) : result =
  (true, Yojson.Safe.to_string (Command_plane_v2.observe_capacity_json ctx.config))

let handle_observe_traces (ctx : (_, _) context) args : result =
  let operation_id = get_string_opt args "operation_id" in
  let limit =
    match Yojson.Safe.Util.member "limit" args with
    | `Int value -> value
    | _ -> 25
  in
  ( true,
    Yojson.Safe.to_string
      (Command_plane_v2.list_traces_json ctx.config ?operation_id ~limit ()))
