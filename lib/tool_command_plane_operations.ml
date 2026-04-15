open Tool_command_plane_support

(** Command plane operations.
    Helper utilities and handlers for command-plane tool surface. *)

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

(* --- Operation handlers --- *)

let handle_operation_status (ctx : (_, _) context) args : tool_result =
  let operation_id = get_string_opt args "operation_id" in
  ( true,
    Yojson.Safe.to_string
      (Command_plane_v2.operation_status_json ctx.config ?operation_id ()) )

let handle_operation_start (ctx : (_, _) context) args : tool_result =
  try
    match
      Command_plane_v2.start_operation ctx.config ~actor:ctx.agent_name args
    with
    | Ok operation ->
        ( true,
          json_ok
            [
              ("result", Command_plane_v2.operation_to_json operation);
              ("operations", Command_plane_v2.operation_status_json ctx.config ());
            ] )
    | Error message -> (false, json_error message)
  with Invalid_argument message -> (false, json_error message)

let handle_operation_checkpoint (ctx : (_, _) context) args : tool_result =
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

(* --- Intent handlers --- *)

let handle_intent_create (ctx : (_, _) context) args : tool_result =
  (match Command_plane_v2.create_intent_json ctx.config ~actor:ctx.agent_name args with
  | Ok intent -> (true, json_ok [ ("result", Command_plane_v2.intent_to_json intent) ])
  | Error message -> (false, json_error message))

let handle_intent_status (ctx : (_, _) context) args : tool_result =
  let intent_id = get_string_opt args "intent_id" in
  (true, Yojson.Safe.to_string (Command_plane_v2.list_intents_json ?intent_id ctx.config))

let handle_intent_update (ctx : (_, _) context) args : tool_result =
  (match Command_plane_v2.update_intent_json ctx.config ~actor:ctx.agent_name args with
  | Ok intent -> (true, json_ok [ ("result", Command_plane_v2.intent_to_json intent) ])
  | Error message -> (false, json_error message))

let handle_intent_forecast (ctx : (_, _) context) args : tool_result =
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

(* --- Observe handlers --- *)

let handle_observe_topology (ctx : (_, _) context) : tool_result =
  (true, Yojson.Safe.to_string (Command_plane_v2.topology_json ctx.config))

let handle_observe_alerts (ctx : (_, _) context) : tool_result =
  (true, Yojson.Safe.to_string (Command_plane_v2.list_alerts_json ctx.config))

let handle_observe_operations (ctx : (_, _) context) : tool_result =
  (true, Yojson.Safe.to_string (Command_plane_v2.observe_operations_json ctx.config))

let handle_observe_swarm (ctx : (_, _) context) args : tool_result =
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
              ("room_id", `String "default");
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
              ("room_id", `String "default");
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

let handle_observe_capacity (ctx : (_, _) context) : tool_result =
  (true, Yojson.Safe.to_string (Command_plane_v2.observe_capacity_json ctx.config))

let handle_observe_traces (ctx : (_, _) context) args : tool_result =
  let operation_id = get_string_opt args "operation_id" in
  let limit =
    match Yojson.Safe.Util.member "limit" args with
    | `Int value -> value
    | _ -> 25
  in
  ( true,
    Yojson.Safe.to_string
      (Command_plane_v2.list_traces_json ctx.config ?operation_id ~limit ()))
