(** MCP tools for long-running team sessions (1h orchestration). *)

open Types

type 'a context = {
  config : Room.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
}

type result = bool * string

let get_string args key default =
  match Yojson.Safe.Util.member key args with
  | `String s -> s
  | _ -> default

let get_string_opt args key =
  match Yojson.Safe.Util.member key args with
  | `String s ->
      let t = String.trim s in
      if t = "" then None else Some t
  | _ -> None

let get_int args key default =
  match Yojson.Safe.Util.member key args with
  | `Int n -> n
  | `Intlit s -> (try int_of_string s with _ -> default)
  | _ -> default

let get_bool args key default =
  match Yojson.Safe.Util.member key args with
  | `Bool b -> b
  | _ -> default

let get_string_list args key =
  match Yojson.Safe.Util.member key args with
  | `List xs ->
      xs
      |> List.filter_map (function
             | `String s ->
                 let t = String.trim s in
                 if t = "" then None else Some t
             | _ -> None)
  | _ -> []

let json_error message =
  Yojson.Safe.to_string
    (`Assoc [ ("status", `String "error"); ("message", `String message) ])

let json_ok fields =
  Yojson.Safe.to_string (`Assoc (("status", `String "ok") :: fields))

let parse_execution_scope args =
  match String.lowercase_ascii (get_string args "execution_scope" "observe_only") with
  | "limited_code_change" -> Team_session_types.Limited_code_change
  | _ -> Team_session_types.Observe_only

let parse_orchestration_mode args =
  match String.lowercase_ascii (get_string args "orchestration_mode" "assist") with
  | "manual" -> Team_session_types.Manual
  | "auto" -> Team_session_types.Auto
  | _ -> Team_session_types.Assist

let parse_communication_mode args =
  match String.lowercase_ascii (get_string args "communication_mode" "broadcast") with
  | "off" -> Team_session_types.Comm_off
  | "portal" -> Team_session_types.Comm_portal
  | "hybrid" -> Team_session_types.Comm_hybrid
  | _ -> Team_session_types.Comm_broadcast

let parse_fallback_policy args =
  match String.lowercase_ascii (get_string args "fallback_policy" "cascade_then_task") with
  | "none" -> Team_session_types.Fallback_none
  | "task_only" -> Team_session_types.Fallback_task_only
  | _ -> Team_session_types.Fallback_cascade_then_task

let parse_instruction_profile args =
  match String.lowercase_ascii (get_string args "instruction_profile" "standard") with
  | "strict" -> Team_session_types.Profile_strict
  | _ -> Team_session_types.Profile_standard

let parse_alert_channel args =
  match String.lowercase_ascii (get_string args "alert_channel" "both") with
  | "broadcast" -> Team_session_types.Alert_broadcast
  | "board" -> Team_session_types.Alert_board
  | _ -> Team_session_types.Alert_both

let parse_report_formats args =
  let raw = get_string_list args "report_formats" in
  let parsed = Team_session_types.report_formats_of_strings raw in
  if parsed = [] then [ Team_session_types.Markdown; Team_session_types.Json ]
  else parsed

let is_all_digits s =
  let len = String.length s in
  len > 0 && String.for_all (function '0' .. '9' -> true | _ -> false) s

let is_all_hex s =
  let len = String.length s in
  len > 0
  && String.for_all
       (function
         | '0' .. '9'
         | 'a' .. 'f'
         | 'A' .. 'F' ->
             true
         | _ -> false)
       s

let is_valid_session_id session_id =
  match String.split_on_char '-' session_id with
  | [ "ts"; epoch_ms; suffix ] -> is_all_digits epoch_ms && is_all_hex suffix
  | _ -> false

let get_valid_session_id_key args key =
  match get_string_opt args key with
  | None -> Error (key ^ " is required")
  | Some session_id ->
      if is_valid_session_id session_id then
        Ok session_id
      else
        Error ("invalid " ^ key ^ " format")

let get_valid_session_id args = get_valid_session_id_key args "session_id"

let parse_status_filter args =
  match get_string_opt args "status" with
  | None -> Ok None
  | Some status ->
      let normalized = String.lowercase_ascii (String.trim status) in
      match normalized with
      | "running" | "paused" | "completed" | "interrupted" | "failed" ->
          Ok (Some (Team_session_types.status_of_string normalized))
      | _ -> Error "invalid status filter"

let can_access_session ~agent_name (session : Team_session_types.session) =
  String.equal agent_name session.created_by
  || List.exists (String.equal agent_name) session.agent_names

let ensure_session_access ctx session_id =
  match Team_session_store.load_session ctx.config session_id with
  | None -> Error (Printf.sprintf "team session not found: %s" session_id)
  | Some session ->
      if can_access_session ~agent_name:ctx.agent_name session then
        Ok ()
      else
        Error "not authorized for this team session"

let handle_start ctx args : result =
  let goal = get_string args "goal" "" in
  if String.trim goal = "" then
    (false, json_error "goal is required")
  else
    let duration_seconds = get_int args "duration_seconds" 3600 in
    let checkpoint_interval_sec = get_int args "checkpoint_interval_sec" 60 in
    let min_agents = get_int args "min_agents" 2 in
    let auto_resume = get_bool args "auto_resume" true in
    let report_formats = parse_report_formats args in
    let execution_scope = parse_execution_scope args in
    let orchestration_mode = parse_orchestration_mode args in
    let communication_mode = parse_communication_mode args in
    let model_cascade = get_string_list args "model_cascade" in
    let fallback_policy = parse_fallback_policy args in
    let instruction_profile = parse_instruction_profile args in
    let alert_channel = parse_alert_channel args in
    let agents = get_string_list args "agents" in
    match
      Team_session_engine_eio.start_session ~sw:ctx.sw ~clock:ctx.clock
        ~config:ctx.config ~created_by:ctx.agent_name ~goal ~duration_seconds
        ~execution_scope ~checkpoint_interval_sec ~min_agents
        ~orchestration_mode ~communication_mode ~model_cascade ~fallback_policy
        ~instruction_profile ~alert_channel ~auto_resume ~report_formats
        ~agent_names:agents
    with
    | Ok json -> (true, json_ok [ ("result", json) ])
    | Error e -> (false, json_error e)

let handle_status ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () -> (
          match Team_session_engine_eio.status_session ~config:ctx.config ~session_id with
          | Ok json -> (true, json_ok [ ("result", json) ])
          | Error e -> (false, json_error e)))

let handle_stop ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () ->
          let reason = get_string args "reason" "manual_stop" in
          let generate_report = get_bool args "generate_report" true in
          (match
             Team_session_engine_eio.stop_session ~config:ctx.config ~session_id
               ~reason ~generate_report
           with
          | Ok json -> (true, json_ok [ ("result", json) ])
          | Error e -> (false, json_error e)))

let handle_report ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () ->
          let force_regenerate = get_bool args "force_regenerate" false in
          (match
             Team_session_engine_eio.generate_report ~config:ctx.config ~session_id
               ~force_regenerate
           with
          | Ok json -> (true, json_ok [ ("result", json) ])
          | Error e -> (false, json_error e)))

let handle_list ctx args : result =
  let limit = get_int args "limit" 20 in
  match parse_status_filter args with
  | Error e -> (false, json_error e)
  | Ok status_filter -> (
      match
        Team_session_engine_eio.list_sessions ~config:ctx.config
          ~requester_agent:(Some ctx.agent_name) ~status_filter ~limit
      with
      | Ok json -> (true, json_ok [ ("result", json) ])
      | Error e -> (false, json_error e))

let handle_compare ctx args : result =
  match
    ( get_valid_session_id_key args "base_session_id",
      get_valid_session_id_key args "target_session_id" )
  with
  | Ok base_session_id, Ok target_session_id -> (
      match
        Team_session_engine_eio.compare_sessions ~config:ctx.config
          ~requester_agent:(Some ctx.agent_name) ~base_session_id
          ~target_session_id
      with
      | Ok json -> (true, json_ok [ ("result", json) ])
      | Error e -> (false, json_error e))
  | Error e, _ -> (false, json_error e)
  | _, Error e -> (false, json_error e)

let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_team_session_start" -> Some (handle_start ctx args)
  | "masc_team_session_status" -> Some (handle_status ctx args)
  | "masc_team_session_stop" -> Some (handle_stop ctx args)
  | "masc_team_session_report" -> Some (handle_report ctx args)
  | "masc_team_session_list" -> Some (handle_list ctx args)
  | "masc_team_session_compare" -> Some (handle_compare ctx args)
  | _ -> None

let schemas : tool_schema list =
  [
    {
      name = "masc_team_session_start";
      description =
        "Start a long-running team collaboration session with periodic checkpoints and final report artifacts.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ( "goal",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("description", `String "Session goal (required)");
                      ] );
                  ( "duration_seconds",
                    `Assoc
                      [
                        ("type", `String "integer");
                        ( "description",
                          `String
                            "Session duration in seconds (default: 3600)" );
                      ] );
                  ( "execution_scope",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "observe_only";
                              `String "limited_code_change";
                            ] );
                      ] );
                  ( "checkpoint_interval_sec",
                    `Assoc
                      [
                        ("type", `String "integer");
                        ( "description",
                          `String "Checkpoint interval in seconds (default: 60)"
                        );
                      ] );
                  ( "min_agents",
                    `Assoc
                      [
                        ("type", `String "integer");
                        ( "description",
                          `String "Minimum expected participating agents" );
                      ] );
                  ( "orchestration_mode",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "manual";
                              `String "assist";
                              `String "auto";
                            ] );
                      ] );
                  ( "communication_mode",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "off";
                              `String "broadcast";
                              `String "portal";
                              `String "hybrid";
                            ] );
                      ] );
                  ( "model_cascade",
                    `Assoc
                      [
                        ("type", `String "array");
                        ("items", `Assoc [ ("type", `String "string") ]);
                      ] );
                  ( "fallback_policy",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "none";
                              `String "cascade_then_task";
                              `String "task_only";
                            ] );
                      ] );
                  ( "instruction_profile",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("enum", `List [ `String "standard"; `String "strict" ]);
                      ] );
                  ( "alert_channel",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [ `String "broadcast"; `String "board"; `String "both" ]
                        );
                      ] );
                  ( "auto_resume",
                    `Assoc
                      [
                        ("type", `String "boolean");
                        ( "description",
                          `String "Recover and resume after process restart" );
                      ] );
                  ( "report_formats",
                    `Assoc
                      [
                        ("type", `String "array");
                        ("items", `Assoc [ ("type", `String "string") ]);
                      ] );
                  ( "agents",
                    `Assoc
                      [
                        ("type", `String "array");
                        ("items", `Assoc [ ("type", `String "string") ]);
                      ] );
                ] );
            ("required", `List [ `String "goal" ]);
          ];
    };
    {
      name = "masc_team_session_status";
      description = "Get the current status and progress summary for a team session.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc [ ("session_id", `Assoc [ ("type", `String "string") ]) ]
            );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_team_session_stop";
      description =
        "Request stop for a team session and optionally generate report artifacts.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ("reason", `Assoc [ ("type", `String "string") ]);
                  ("generate_report", `Assoc [ ("type", `String "boolean") ]);
                ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_team_session_report";
      description = "Generate (or regenerate) report artifacts for a team session.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ("force_regenerate", `Assoc [ ("type", `String "boolean") ]);
                ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_team_session_list";
      description =
        "List recent team sessions with optional status filter and health/cascade summary.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("status", `Assoc [ ("type", `String "string") ]);
                  ( "limit",
                    `Assoc
                      [
                        ("type", `String "integer");
                        ("description", `String "Max sessions to return (default: 20)");
                      ] );
                ] );
          ];
    };
    {
      name = "masc_team_session_compare";
      description =
        "Compare two team sessions and return throughput/policy/communication deltas.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("base_session_id", `Assoc [ ("type", `String "string") ]);
                  ("target_session_id", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "base_session_id"; `String "target_session_id" ]);
          ];
    };
  ]
