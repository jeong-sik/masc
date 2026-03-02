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
  Yojson.Safe.to_string (`Assoc [ ("status", `String "error"); ("message", `String message) ])

let json_ok fields =
  Yojson.Safe.to_string (`Assoc (("status", `String "ok") :: fields))

let parse_execution_scope args =
  match String.lowercase_ascii (get_string args "execution_scope" "observe_only") with
  | "limited_code_change" -> Team_session_types.Limited_code_change
  | _ -> Team_session_types.Observe_only

let parse_report_formats args =
  let raw = get_string_list args "report_formats" in
  let parsed = Team_session_types.report_formats_of_strings raw in
  if parsed = [] then [ Team_session_types.Markdown; Team_session_types.Json ] else parsed

let is_all_digits s =
  let len = String.length s in
  len > 0
  && String.for_all (function '0' .. '9' -> true | _ -> false) s

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

let get_valid_session_id args =
  match get_string_opt args "session_id" with
  | None -> Error "session_id is required"
  | Some session_id ->
      if is_valid_session_id session_id then
        Ok session_id
      else
        Error "invalid session_id format"

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
    let agents = get_string_list args "agents" in
    match
      Team_session_engine_eio.start_session ~sw:ctx.sw ~clock:ctx.clock
        ~config:ctx.config ~created_by:ctx.agent_name ~goal ~duration_seconds
        ~execution_scope ~checkpoint_interval_sec ~min_agents ~auto_resume
        ~report_formats ~agent_names:agents
    with
    | Ok json -> (true, json_ok [ ("result", json) ])
    | Error e -> (false, json_error e)

let handle_status ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match Team_session_engine_eio.status_session ~config:ctx.config ~session_id with
      | Ok json -> (true, json_ok [ ("result", json) ])
      | Error e -> (false, json_error e))

let handle_stop ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id ->
      let reason = get_string args "reason" "manual_stop" in
      let generate_report = get_bool args "generate_report" true in
      (match
         Team_session_engine_eio.stop_session ~config:ctx.config ~session_id
           ~reason ~generate_report
       with
      | Ok json -> (true, json_ok [ ("result", json) ])
      | Error e -> (false, json_error e))

let handle_report ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id ->
      let force_regenerate = get_bool args "force_regenerate" false in
      (match
         Team_session_engine_eio.generate_report ~config:ctx.config ~session_id
           ~force_regenerate
       with
      | Ok json -> (true, json_ok [ ("result", json) ])
      | Error e -> (false, json_error e))

let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_team_session_start" -> Some (handle_start ctx args)
  | "masc_team_session_status" -> Some (handle_status ctx args)
  | "masc_team_session_stop" -> Some (handle_stop ctx args)
  | "masc_team_session_report" -> Some (handle_report ctx args)
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
                  ("goal", `Assoc [ ("type", `String "string"); ("description", `String "Session goal (required)") ]);
                  ("duration_seconds", `Assoc [ ("type", `String "integer"); ("description", `String "Session duration in seconds (default: 3600)") ]);
                  ("execution_scope", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "observe_only"; `String "limited_code_change" ]) ]);
                  ("checkpoint_interval_sec", `Assoc [ ("type", `String "integer"); ("description", `String "Checkpoint interval in seconds (default: 60)") ]);
                  ("min_agents", `Assoc [ ("type", `String "integer"); ("description", `String "Minimum expected participating agents") ]);
                  ("auto_resume", `Assoc [ ("type", `String "boolean"); ("description", `String "Recover and resume after process restart") ]);
                  ("report_formats", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
                  ("agents", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
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
            ("properties", `Assoc [ ("session_id", `Assoc [ ("type", `String "string") ]) ]);
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_team_session_stop";
      description = "Request stop for a team session and optionally generate report artifacts.";
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
  ]
