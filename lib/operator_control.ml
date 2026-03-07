module U = Yojson.Safe.Util

let ( let* ) = Result.bind

type 'a context = {
  config : Room.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
  mcp_session_id : string option;
}

type pending_confirm = {
  token : string;
  trace_id : string;
  actor : string;
  action_type : string;
  target_type : string;
  target_id : string option;
  payload : Yojson.Safe.t;
  delegated_tool : string;
  created_at : string;
  expires_at : string option;
}

type action_log_entry = {
  trace_id : string;
  actor : string;
  remote_session_id : string option;
  remote_client_type : string;
  action_type : string;
  target_type : string;
  target_id : string option;
  delegated_tool : string;
  confirmation_state : string;
  result_status : string;
  latency_ms : int;
  created_at : string;
}

let json_ok fields =
  `Assoc (("status", `String "ok") :: fields)

let get_string args key default =
  match U.member key args with
  | `String s -> s
  | _ -> default

let get_string_opt args key =
  match U.member key args with
  | `String s ->
      let trimmed = String.trim s in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let get_int args key default =
  match U.member key args with
  | `Int n -> n
  | `Intlit s -> (try int_of_string s with _ -> default)
  | _ -> default

let get_bool args key default =
  match U.member key args with
  | `Bool b -> b
  | _ -> default

let get_payload args =
  match U.member "payload" args with
  | `Assoc _ as payload -> payload
  | _ -> `Assoc []

let option_to_json f = function
  | Some value -> f value
  | None -> `Null

let string_option_to_json = option_to_json (fun value -> `String value)

let normalized_actor ~context_actor = function
  | Some raw when String.trim raw <> "" -> String.trim raw
  | _ ->
      let trimmed = String.trim context_actor in
      if trimmed = "" || String.equal trimmed "unknown" then "dashboard" else trimmed

let operator_dir config =
  Filename.concat (Room.masc_dir config) "operator"

let pending_confirms_path config =
  Filename.concat (operator_dir config) "pending_confirms.json"

let action_log_path config =
  Filename.concat (operator_dir config) "action_log.jsonl"

let remote_confirm_ttl_seconds = 900.0

let trace_id prefix =
  let entropy =
    Printf.sprintf "%s|%d|%.6f|%d"
      prefix (Unix.getpid ()) (Unix.gettimeofday ()) (Random.bits ())
  in
  let digest = Digestif.SHA256.(digest_string entropy |> to_hex) in
  prefix ^ "_" ^ String.sub digest 0 16

let iso_of_unix unix_ts =
  let tm = Unix.gmtime unix_ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let remote_client_type_of_context (ctx : 'a context) =
  match ctx.mcp_session_id with
  | Some _ -> "mcp_remote"
  | None -> "local_api"

let operator_server_profile_json =
  `Assoc
    [
      ("name", `String "operator_remote_v1");
      ("transport", `String "mcp_streamable_http");
      ("auth", `String "bearer_token");
      ("confirm_ttl_seconds", `Float remote_confirm_ttl_seconds);
      ("curated_tool_count", `Int 3);
    ]

let preview_of_pending_confirm (entry : pending_confirm) =
  `Assoc
    [
      ("trace_id", `String entry.trace_id);
      ("actor", `String entry.actor);
      ("action_type", `String entry.action_type);
      ("target_type", `String entry.target_type);
      ("target_id", string_option_to_json entry.target_id);
      ("payload", entry.payload);
    ]

let pending_confirm_to_yojson (entry : pending_confirm) =
  `Assoc
    [
      ("token", `String entry.token);
      ("confirm_token", `String entry.token);
      ("trace_id", `String entry.trace_id);
      ("actor", `String entry.actor);
      ("action_type", `String entry.action_type);
      ("target_type", `String entry.target_type);
      ("target_id", string_option_to_json entry.target_id);
      ("payload", entry.payload);
      ("delegated_tool", `String entry.delegated_tool);
      ("created_at", `String entry.created_at);
      ("expires_at", string_option_to_json entry.expires_at);
      ("preview", preview_of_pending_confirm entry);
    ]

let pending_confirm_of_yojson json =
  try
    let token = json |> U.member "token" |> U.to_string in
    let trace_id =
      match json |> U.member "trace_id" |> U.to_string_option with
      | Some value -> value
      | None -> trace_id "opc"
    in
    let actor = json |> U.member "actor" |> U.to_string in
    let action_type = json |> U.member "action_type" |> U.to_string in
    let target_type = json |> U.member "target_type" |> U.to_string in
    let target_id = json |> U.member "target_id" |> U.to_string_option in
    let payload =
      match json |> U.member "payload" with
      | `Assoc _ as payload -> payload
      | _ -> `Assoc []
    in
    let delegated_tool = json |> U.member "delegated_tool" |> U.to_string in
    let created_at = json |> U.member "created_at" |> U.to_string in
    let expires_at = json |> U.member "expires_at" |> U.to_string_option in
    Ok
      {
        token;
        trace_id;
        actor;
        action_type;
        target_type;
        target_id;
        payload;
        delegated_tool;
        created_at;
        expires_at;
      }
  with U.Type_error (msg, _) | Failure msg -> Error msg

let raw_pending_confirms config : pending_confirm list =
  match Room_utils.read_json_opt config (pending_confirms_path config) with
  | None -> []
  | Some (`List entries) ->
      List.filter_map
        (fun json ->
          match pending_confirm_of_yojson json with
          | Ok entry -> Some entry
          | Error _ -> None)
        entries
  | Some _ -> []

let write_pending_confirms config (entries : pending_confirm list) =
  Room_utils.write_json config (pending_confirms_path config)
    (`List (List.map pending_confirm_to_yojson entries))

let pending_confirm_expired (entry : pending_confirm) =
  match entry.expires_at with
  | Some exp -> Types.now_iso () > exp
  | None -> false

let read_pending_confirms config : pending_confirm list =
  let entries = raw_pending_confirms config in
  let active = List.filter (fun entry -> not (pending_confirm_expired entry)) entries in
  if List.length active <> List.length entries then write_pending_confirms config active;
  active

let upsert_pending_confirm config entry =
  let remaining =
    read_pending_confirms config
    |> List.filter (fun existing -> not (String.equal existing.token entry.token))
  in
  write_pending_confirms config (entry :: remaining)

let remove_pending_confirm config token =
  let remaining =
    read_pending_confirms config
    |> List.filter (fun existing -> not (String.equal existing.token token))
  in
  write_pending_confirms config remaining

let pending_confirms_json ?actor config =
  let actor_filter =
    match actor with
    | Some raw ->
        let trimmed = String.trim raw in
        if trimmed = "" then None else Some trimmed
    | None -> None
  in
  let rows : pending_confirm list =
    read_pending_confirms config
    |> List.filter (fun (entry : pending_confirm) ->
           match actor_filter with
           | None -> true
           | Some value -> String.equal value entry.actor)
    |> List.sort (fun (a : pending_confirm) (b : pending_confirm) ->
           String.compare b.created_at a.created_at)
  in
  `List (List.map pending_confirm_to_yojson rows)

let action_log_entry_to_yojson (entry : action_log_entry) =
  `Assoc
    [
      ("trace_id", `String entry.trace_id);
      ("actor", `String entry.actor);
      ("remote_session_id", string_option_to_json entry.remote_session_id);
      ("remote_client_type", `String entry.remote_client_type);
      ("action_type", `String entry.action_type);
      ("target_type", `String entry.target_type);
      ("target_id", string_option_to_json entry.target_id);
      ("delegated_tool", `String entry.delegated_tool);
      ("confirmation_state", `String entry.confirmation_state);
      ("result_status", `String entry.result_status);
      ("latency_ms", `Int entry.latency_ms);
      ("created_at", `String entry.created_at);
    ]

let append_action_log config (entry : action_log_entry) =
  Room_utils.mkdir_p (operator_dir config);
  let oc =
    open_out_gen [ Open_creat; Open_text; Open_append ] 0o644
      (action_log_path config)
  in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      output_string oc (Yojson.Safe.to_string (action_log_entry_to_yojson entry));
      output_char oc '\n')

let recent_actions_json config =
  if not (Sys.file_exists (action_log_path config)) then
    `List []
  else
    let lines =
      In_channel.with_open_text (action_log_path config) In_channel.input_lines
    in
    let tail =
      let rev = List.rev lines in
      rev |> List.to_seq |> Seq.take 20 |> List.of_seq |> List.rev
    in
    let items =
      tail
      |> List.filter_map (fun line ->
             try Some (Yojson.Safe.from_string line) with Yojson.Json_error _ -> None)
    in
    `List items

let available_actions_json =
  `List
    [
      `Assoc
        [
          ("action_type", `String "broadcast");
          ("target_type", `String "room");
          ("description", `String "Use this when you need a room-wide operator broadcast.");
          ("confirm_required", `Bool false);
        ];
      `Assoc
        [
          ("action_type", `String "room_pause");
          ("target_type", `String "room");
          ("description", `String "Use this when you need to pause room automation or spawning.");
          ("confirm_required", `Bool true);
        ];
      `Assoc
        [
          ("action_type", `String "room_resume");
          ("target_type", `String "room");
          ("description", `String "Use this when you need to resume a paused room.");
          ("confirm_required", `Bool false);
        ];
      `Assoc
        [
          ("action_type", `String "lodge_tick");
          ("target_type", `String "room");
          ("description", `String "Use this when you need to run one immediate Lodge tick and inspect which agents acted or were skipped.");
          ("confirm_required", `Bool false);
        ];
      `Assoc
        [
          ("action_type", `String "team_note");
          ("target_type", `String "team_session");
          ("description", `String "Use this when you need to append a non-broadcast operator note to a team session.");
          ("confirm_required", `Bool false);
        ];
      `Assoc
        [
          ("action_type", `String "team_broadcast");
          ("target_type", `String "team_session");
          ("description", `String "Use this when you need a broadcast-style orchestration turn in a team session.");
          ("confirm_required", `Bool false);
        ];
      `Assoc
        [
          ("action_type", `String "team_task_inject");
          ("target_type", `String "team_session");
          ("description", `String "Use this when you need to inject a new task into a running team session.");
          ("confirm_required", `Bool true);
        ];
      `Assoc
        [
          ("action_type", `String "team_stop");
          ("target_type", `String "team_session");
          ("description", `String "Use this when you need to stop a running team session.");
          ("confirm_required", `Bool true);
        ];
      `Assoc
        [
          ("action_type", `String "keeper_message");
          ("target_type", `String "keeper");
          ("description", `String "Use this when you need to send a direct operator message to a keeper.");
          ("confirm_required", `Bool false);
        ];
      `Assoc
        [
          ("action_type", `String "keeper_probe");
          ("target_type", `String "keeper");
          ("description", `String "Use this when you need an immediate keeper diagnostic snapshot with health, silence reason, and next suggested action.");
          ("confirm_required", `Bool false);
        ];
      `Assoc
        [
          ("action_type", `String "keeper_recover");
          ("target_type", `String "keeper");
          ("description", `String "Use this when a keeper is stale, degraded, or offline and you need a safe down/up recovery with before-and-after diagnostics.");
          ("confirm_required", `Bool false);
        ];
    ]

let recent_messages_json config =
  Room.get_messages_raw config ~since_seq:0 ~limit:20
  |> List.map Types.message_to_yojson
  |> fun rows -> `List rows

let keepers_json config =
  let dir = Tool_keeper.keeper_dir config in
  let names =
    if not (Sys.file_exists dir) then
      []
    else
      Sys.readdir dir
      |> Array.to_list
      |> List.filter (fun file -> Filename.check_suffix file ".json")
      |> List.map Filename.remove_extension
      |> List.filter Tool_keeper.validate_name
      |> List.sort String.compare
  in
  let rows =
    List.filter_map
      (fun name ->
        match Tool_keeper.read_meta config name with
        | Error _ | Ok None -> None
        | Ok (Some meta) ->
            let agent_json =
              Tool_keeper.parse_agent_status config ~agent_name:meta.agent_name
            in
            let agent_status =
              match agent_json |> U.member "status" with
              | `String status -> status
              | _ -> "unknown"
            in
            Some
              (`Assoc
                [
                  ("name", `String meta.name);
                  ("agent_name", `String meta.agent_name);
                  ("trace_id", `String meta.trace_id);
                  ("goal", `String meta.goal);
                  ("short_goal", `String meta.short_goal);
                  ("mid_goal", `String meta.mid_goal);
                  ("long_goal", `String meta.long_goal);
                  ("status", `String agent_status);
                  ("generation", `Int meta.generation);
                  ("turn_count", `Int meta.total_turns);
                  ("context_ratio", `Null);
                  ("context_tokens", `Int meta.last_total_tokens);
                  ("last_model_used", `String meta.last_model_used);
                  ("active_model", `String (Tool_keeper.active_model_of_meta meta));
                  ( "next_model_hint",
                    string_option_to_json (Tool_keeper.next_model_hint_of_meta meta)
                  );
                  ("autonomy_level", `String meta.autonomy_level);
                  ( "active_goal_ids",
                    `List (List.map (fun goal_id -> `String goal_id) meta.active_goal_ids)
                  );
                  ( "last_autonomous_action_at",
                    if String.trim meta.last_autonomous_action_at = "" then `Null
                    else `String meta.last_autonomous_action_at );
                  ("autonomous_action_count", `Int meta.autonomous_action_count);
                  ("updated_at", `String meta.updated_at);
                  ("created_at", `String meta.created_at);
                ]))
      names
  in
  `Assoc [ ("count", `Int (List.length rows)); ("items", `List rows) ]

let sessions_json config =
  let sessions =
    Team_session_store.list_sessions config
    |> List.sort (fun (a : Team_session_types.session) (b : Team_session_types.session) ->
           compare b.started_at a.started_at)
  in
  let items =
    List.map
      (fun (session : Team_session_types.session) ->
        let recent_events =
          Team_session_store.read_events ~max_events:200 config session.session_id
          |> Team_session_engine_eio.take_last 5
        in
        `Assoc
          [
            ("session_id", `String session.session_id);
            ("command_plane_operation_id", `String ("detachment-" ^ session.session_id));
            ("command_plane_detachment_id", `String ("detachment-" ^ session.session_id));
            ("status", Team_session_engine_eio.session_status_json config session);
            ("recent_events", `List recent_events);
          ])
      sessions
  in
  `Assoc [ ("count", `Int (List.length items)); ("items", `List items) ]

let room_json config =
  let initialized = Room.is_initialized config in
  if not initialized then
    `Assoc
      [
        ("initialized", `Bool false);
        ("project", `String (Filename.basename config.base_path));
      ]
  else
    let state = Room.read_state config in
    let tempo = Tempo.get_tempo config in
    let tasks = Room.get_tasks_raw config in
    let agents = Room.get_agents_raw config in
    `Assoc
      [
        ("initialized", `Bool true);
        ("cluster", `String (Option.value ~default:"default" (Sys.getenv_opt "MASC_CLUSTER_NAME")));
        ("project", `String state.project);
        ("current_room", string_option_to_json (Room.read_current_room config));
        ("paused", `Bool state.paused);
        ("pause_reason", string_option_to_json state.pause_reason);
        ("paused_by", string_option_to_json state.paused_by);
        ("paused_at", string_option_to_json state.paused_at);
        ("tempo_interval_s", `Float tempo.current_interval_s);
        ("agent_count", `Int (List.length agents));
        ("task_count", `Int (List.length tasks));
        ("message_seq", `Int state.message_seq);
      ]

type snapshot_view =
  | Summary
  | Sessions
  | Keepers
  | Messages
  | Full

let parse_snapshot_view = function
  | Some raw -> (
      match String.trim raw |> String.lowercase_ascii with
      | "summary" -> Summary
      | "sessions" -> Sessions
      | "keepers" -> Keepers
      | "messages" -> Messages
      | _ -> Full)
  | None -> Full

let snapshot_json ?actor ?view ?(include_messages = true) ?(include_sessions = true)
    ?(include_keepers = true) (ctx : 'a context) : Yojson.Safe.t =
  let config = ctx.config in
  let initialized = Room.is_initialized config in
  let trace_id = trace_id "ops" in
  let view = parse_snapshot_view view in
  let include_sessions =
    include_sessions
    &&
    match view with
    | Summary | Sessions | Full -> true
    | Keepers | Messages -> false
  in
  let include_keepers =
    include_keepers
    &&
    match view with
    | Summary | Keepers | Full -> true
    | Sessions | Messages -> false
  in
  let include_messages =
    include_messages
    &&
    match view with
    | Summary | Messages | Full -> true
    | Sessions | Keepers -> false
  in
  `Assoc
    [
      ("trace_id", `String trace_id);
      ("server_profile", operator_server_profile_json);
      ("room", room_json config);
      ( "sessions",
        if initialized && include_sessions then sessions_json config
        else `Assoc [ ("count", `Int 0); ("items", `List []) ] );
      ( "keepers",
        if initialized && include_keepers then keepers_json config
        else `Assoc [ ("count", `Int 0); ("items", `List []) ] );
      ("command_plane", if initialized then Command_plane_v2.snapshot_json config else `Assoc []);
      ("recent_messages", if initialized && include_messages then recent_messages_json config else `List []);
      ("pending_confirms", pending_confirms_json ?actor config);
      ("available_actions", available_actions_json);
      ("recent_actions", recent_actions_json config);
    ]

type action_request = {
  actor : string;
  action_type : string;
  target_type : string;
  target_id : string option;
  payload : Yojson.Safe.t;
}

let canonical_action_type action_type =
  match action_type with
  | "lodge_poke" -> "lodge_tick"
  | "lodge_tick" -> "lodge_tick"
  | "team_turn" -> "team_turn"
  | "team_note" -> "team_note"
  | "team_broadcast" -> "team_broadcast"
  | "team_task_inject" -> "team_task_inject"
  | "keeper_msg" -> "keeper_message"
  | "keeper_message" -> "keeper_message"
  | "keeper_probe" -> "keeper_probe"
  | "keeper_recover" -> "keeper_recover"
  | other -> other

let default_target_type_for action_type =
  match action_type with
  | "broadcast" | "room_pause" | "room_resume" | "task_inject" | "lodge_tick" -> "room"
  | "team_turn" | "team_note" | "team_broadcast" | "team_task_inject" | "team_stop" -> "team_session"
  | "keeper_message" | "keeper_probe" | "keeper_recover" -> "keeper"
  | _ -> ""

let generate_confirm_token config =
  let rec loop attempts =
    if attempts > 8 then
      failwith "failed to generate unique confirm token"
    else
      let token = "opc_" ^ String.sub (Auth.generate_token ()) 0 32 in
      let exists =
        raw_pending_confirms config
        |> List.exists (fun entry -> String.equal entry.token token)
      in
      if exists then loop (attempts + 1) else token
  in
  loop 0

let action_request_of_args ?actor_hint ctx args =
  let action_type =
    get_string args "action_type" "" |> String.trim |> String.lowercase_ascii
    |> canonical_action_type
  in
  let raw_target_type =
    get_string args "target_type" "" |> String.trim |> String.lowercase_ascii
  in
  let actor =
    normalized_actor ~context_actor:ctx.agent_name
      (match get_string_opt args "actor" with
      | Some actor -> Some actor
      | None -> actor_hint)
  in
  {
    actor;
    action_type;
    target_type =
      if raw_target_type <> "" then raw_target_type
      else default_target_type_for action_type;
    target_id = get_string_opt args "target_id";
    payload = get_payload args;
  }

let delegated_tool_for action_type =
  match action_type with
  | "broadcast" -> "masc_broadcast"
  | "room_pause" -> "masc_pause"
  | "room_resume" -> "masc_resume"
  | "lodge_tick" -> "lodge_tick"
  | "team_turn" | "team_note" | "team_broadcast" | "team_task_inject" -> "masc_team_session_turn"
  | "team_stop" -> "masc_team_session_stop"
  | "keeper_message" -> "masc_keeper_msg"
  | "keeper_probe" -> "masc_keeper_status"
  | "keeper_recover" -> "masc_keeper_recover"
  | "task_inject" -> "masc_add_task"
  | _ -> "unknown"

let confirm_required = function
  | "room_pause" | "team_stop" | "task_inject" | "team_task_inject" -> true
  | _ -> false

let preview_of_action (request : action_request) =
  let base =
    [
      ("actor", `String request.actor);
      ("action_type", `String request.action_type);
      ("target_type", `String request.target_type);
      ("target_id", string_option_to_json request.target_id);
    ]
  in
  let payload_fields =
    match request.payload with
    | `Assoc fields -> fields
    | _ -> []
  in
  `Assoc (base @ [ ("payload", `Assoc payload_fields) ])

let validate_target_type expected request =
  if String.equal request.target_type expected then Ok ()
  else
    Error
      (Printf.sprintf "invalid target_type for %s (expected %s)"
         request.action_type expected)

let require_target_id request =
  match request.target_id with
  | Some target_id -> Ok target_id
  | None -> Error "target_id is required"

let require_payload_field payload key error_message =
  match get_string_opt payload key with
  | Some value -> Ok value
  | None -> Error error_message

let parse_turn_kind payload =
  match get_string payload "turn_kind" "" |> String.trim |> String.lowercase_ascii with
  | "note" -> Ok Team_session_types.Turn_note
  | "broadcast" -> Ok Team_session_types.Turn_broadcast
  | "task" -> Ok Team_session_types.Turn_task
  | "checkpoint" -> Ok Team_session_types.Turn_checkpoint
  | "" -> Error "payload.turn_kind is required"
  | _ -> Error "payload.turn_kind must be one of: note, broadcast, task, checkpoint"

let json_of_dispatch_output body =
  try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body

let string_of_trigger = function
  | Lodge_heartbeat.Scheduled -> "scheduled"
  | Lodge_heartbeat.ContentAlert _ -> "content_alert"
  | Lodge_heartbeat.Mentioned _ -> "mentioned"
  | Lodge_heartbeat.ManualTrigger -> "manual"

let checkin_json (name, trigger, result) =
  let outcome_fields =
    match result with
    | Lodge_heartbeat.Acted { summary; _ } ->
        [ ("outcome", `String "acted"); ("summary", `String summary) ]
    | Lodge_heartbeat.Passed reason ->
        [ ("outcome", `String "passed"); ("reason", `String reason) ]
    | Lodge_heartbeat.Skipped reason ->
        [ ("outcome", `String "skipped"); ("reason", `String reason) ]
  in
  `Assoc
    ([
       ("name", `String name);
       ("trigger", `String (string_of_trigger trigger));
     ]
    @ outcome_fields)

let lodge_tick_result_json (result : Lodge_heartbeat.heartbeat_result) =
  let skipped_reason =
    if result.agents_checked = 0 then Some "no agents selected for this tick"
    else None
  in
  let acted =
    result.checkins
    |> List.filter_map (fun (name, _, checkin) ->
           match checkin with
           | Lodge_heartbeat.Acted { summary; _ } ->
               Some (`Assoc [ ("name", `String name); ("summary", `String summary) ])
           | Lodge_heartbeat.Passed _ | Lodge_heartbeat.Skipped _ -> None)
  in
  let skipped =
    result.checkins
    |> List.filter_map (fun (name, _, checkin) ->
           match checkin with
           | Lodge_heartbeat.Skipped reason ->
               Some (`Assoc [ ("name", `String name); ("reason", `String reason) ])
           | Lodge_heartbeat.Acted _ | Lodge_heartbeat.Passed _ -> None)
  in
  let passed =
    result.checkins
    |> List.filter_map (fun (name, _, checkin) ->
           match checkin with
           | Lodge_heartbeat.Passed reason ->
               Some (`Assoc [ ("name", `String name); ("reason", `String reason) ])
           | Lodge_heartbeat.Acted _ | Lodge_heartbeat.Skipped _ -> None)
  in
  `Assoc
    [
      ("hour", `Int result.current_hour);
      ("checked", `Int result.agents_checked);
      ("acted", `Int (List.length acted));
      ("acted_names", `List (List.map (fun row -> row |> U.member "name") acted));
      ("activity_report", `String result.activity_report);
      ("quiet_hours_overridden", `Bool true);
      ( "skipped_reason",
        match skipped_reason with Some reason -> `String reason | None -> `Null );
      ("acted_rows", `List acted);
      ("passed_rows", `List passed);
      ("skipped_rows", `List skipped);
      ("checkins", `List (List.map checkin_json result.checkins));
    ]

let tool_keeper_ctx (ctx : 'a context) : _ Tool_keeper.context =
  { config = ctx.config; sw = ctx.sw; clock = ctx.clock }

let dispatch_keeper_json (ctx : 'a context) ~tool_name ~args =
  match Tool_keeper.dispatch (tool_keeper_ctx ctx) ~name:tool_name ~args with
  | Some (true, body) -> Ok (json_of_dispatch_output body)
  | Some (false, err) -> Error err
  | None -> Error (Printf.sprintf "%s dispatch unavailable" tool_name)

let keeper_diagnostic_health_state json =
  match U.member "health_state" json with
  | `String value -> Some (String.lowercase_ascii value)
  | _ -> None

let keeper_diagnostic_recoverable json =
  match U.member "recoverable" json with
  | `Bool value -> value
  | _ -> false

let keeper_recovery_outcome after_diagnostic =
  match keeper_diagnostic_health_state after_diagnostic with
  | Some ("healthy" | "idle") when not (keeper_diagnostic_recoverable after_diagnostic) ->
      (true, None)
  | Some state ->
      ( false,
        Some
          (Printf.sprintf
             "keeper remained %s after recovery attempt"
             state) )
  | None -> (false, Some "keeper recovery did not return a health_state")

let resolve_team_turn_actor config ~requested_actor ~session_id =
  match Team_session_store.load_session config session_id with
  | None -> Error (Printf.sprintf "team session not found: %s" session_id)
  | Some session ->
      if String.equal requested_actor session.created_by
         || List.exists (String.equal requested_actor) session.agent_names
      then
        Ok (requested_actor, false)
      else
        Ok (session.created_by, true)

let execute_team_turn ~ctx ~request ~session_id ~turn_kind ~message ~target_agent
    ~task_title ~task_description ~task_priority =
  let* actor_for_session, operator_override =
    resolve_team_turn_actor ctx.config ~requested_actor:request.actor ~session_id
  in
  let message =
    if operator_override then
      match message with
      | Some raw -> Some (Printf.sprintf "[operator:%s] %s" request.actor raw)
      | None -> Some (Printf.sprintf "[operator:%s]" request.actor)
    else
      message
  in
  let* result =
    Team_session_engine_eio.record_turn ~config:ctx.config ~session_id
      ~actor:actor_for_session ~turn_kind ~message ~target_agent ~task_title
      ~task_description ~task_priority
  in
  Ok
    (`Assoc
      [
        ("delegated_tool", `String "masc_team_session_turn");
        ("result", result);
        ("actor", `String actor_for_session);
        ("operator_override", `Bool operator_override);
      ])

let execute_action (ctx : 'a context) (request : action_request) :
    (Yojson.Safe.t, string) result =
  match request.action_type with
  | "broadcast" ->
      let* () = validate_target_type "room" request in
      let message =
        match get_string_opt request.payload "message" with
        | Some value -> Ok value
        | None -> Error "payload.message is required"
      in
      let* message = message in
      let result = Room.broadcast ctx.config ~from_agent:request.actor ~content:message in
      Ok
        (`Assoc
          [
            ("delegated_tool", `String "masc_broadcast");
            ("result", `String result);
          ])
  | "room_pause" ->
      let* () = validate_target_type "room" request in
      let reason =
        get_string request.payload "reason" "Paused by operator control plane"
      in
      Room.pause ctx.config ~by:request.actor ~reason;
      Ok
        (`Assoc
          [
            ("delegated_tool", `String "masc_pause");
            ("result", `Assoc [ ("paused", `Bool true); ("reason", `String reason) ]);
          ])
  | "room_resume" ->
      let* () = validate_target_type "room" request in
      let status =
        match Room.resume ctx.config ~by:request.actor with
        | `Resumed -> "resumed"
        | `Already_running -> "already_running"
      in
      Ok
        (`Assoc
          [
            ("delegated_tool", `String "masc_resume");
            ("result", `Assoc [ ("status", `String status) ]);
          ])
  | "lodge_tick" ->
      let* () = validate_target_type "room" request in
      if not Env_config.LodgeV2.enabled then
        Ok
          (`Assoc
            [
              ("delegated_tool", `String "lodge_tick");
              ( "result",
                `Assoc
                  [
                    ("checked", `Int 0);
                    ("acted", `Int 0);
                    ("acted_names", `List []);
                    ("quiet_hours_overridden", `Bool true);
                    ("activity_report", `String "Lodge heartbeat is disabled");
                    ("skipped_reason", `String "lodge heartbeat disabled");
                    ("checkins", `List []);
                  ] );
            ])
      else
        let result = Lodge_heartbeat.trigger_heartbeat ctx.config in
        Ok
          (`Assoc
            [
              ("delegated_tool", `String "lodge_tick");
              ("result", lodge_tick_result_json result);
            ])
  | "team_turn" ->
      let* () = validate_target_type "team_session" request in
      let* session_id = require_target_id request in
      let* turn_kind = parse_turn_kind request.payload in
      let message = get_string_opt request.payload "message" in
      let target_agent = get_string_opt request.payload "target_agent" in
      let task_title =
        match get_string_opt request.payload "task_title" with
        | Some value -> Some value
        | None -> get_string_opt request.payload "title"
      in
      let task_description =
        match get_string_opt request.payload "task_description" with
        | Some value -> Some value
        | None -> get_string_opt request.payload "description"
      in
      let task_priority = get_int request.payload "task_priority" (get_int request.payload "priority" 3) in
      execute_team_turn ~ctx ~request ~session_id ~turn_kind ~message ~target_agent
        ~task_title ~task_description ~task_priority
  | "team_note" ->
      let* () = validate_target_type "team_session" request in
      let* session_id = require_target_id request in
      let* message =
        require_payload_field request.payload "message" "payload.message is required"
      in
      execute_team_turn ~ctx ~request ~session_id
        ~turn_kind:Team_session_types.Turn_note ~message:(Some message)
        ~target_agent:None ~task_title:None ~task_description:None
        ~task_priority:3
  | "team_broadcast" ->
      let* () = validate_target_type "team_session" request in
      let* session_id = require_target_id request in
      let* message =
        require_payload_field request.payload "message" "payload.message is required"
      in
      execute_team_turn ~ctx ~request ~session_id
        ~turn_kind:Team_session_types.Turn_broadcast ~message:(Some message)
        ~target_agent:(get_string_opt request.payload "target_agent")
        ~task_title:None ~task_description:None ~task_priority:3
  | "team_task_inject" ->
      let* () = validate_target_type "team_session" request in
      let* session_id = require_target_id request in
      let task_title =
        match get_string_opt request.payload "task_title" with
        | Some value -> Ok value
        | None -> require_payload_field request.payload "title" "payload.task_title or payload.title is required"
      in
      let* task_title = task_title in
      let task_description =
        match get_string_opt request.payload "task_description" with
        | Some value -> Some value
        | None -> get_string_opt request.payload "description"
      in
      let task_priority = get_int request.payload "task_priority" (get_int request.payload "priority" 2) in
      execute_team_turn ~ctx ~request ~session_id
        ~turn_kind:Team_session_types.Turn_task
        ~message:(get_string_opt request.payload "message")
        ~target_agent:(get_string_opt request.payload "target_agent")
        ~task_title:(Some task_title) ~task_description ~task_priority
  | "team_stop" ->
      let* () = validate_target_type "team_session" request in
      let* session_id = require_target_id request in
      let reason =
        get_string request.payload "reason" "Stopped by operator control plane"
      in
      let generate_report = get_bool request.payload "generate_report" true in
      let* result =
        Team_session_engine_eio.stop_session ~config:ctx.config ~session_id
          ~reason ~generate_report
      in
      Ok
        (`Assoc
          [
            ("delegated_tool", `String "masc_team_session_stop");
            ("result", result);
          ])
  | "keeper_probe" ->
      let* () = validate_target_type "keeper" request in
      let* name = require_target_id request in
      let status_args =
        `Assoc
          [
            ("name", `String name);
            ("fast", `Bool false);
            ("include_context", `Bool false);
            ("include_metrics_overview", `Bool true);
            ("include_memory_bank", `Bool false);
            ("include_history_tail", `Bool false);
            ("include_compaction_history", `Bool false);
          ]
      in
      let* status_json =
        dispatch_keeper_json ctx ~tool_name:"masc_keeper_status" ~args:status_args
      in
      let diagnostic =
        match U.member "diagnostic" status_json with
        | `Assoc _ as json -> json
        | _ -> `Null
      in
      Ok
        (`Assoc
          [
            ("delegated_tool", `String "masc_keeper_status");
            ( "result",
              `Assoc
                [
                  ("status", status_json);
                  ("diagnostic", diagnostic);
                ] );
          ])
  | "keeper_recover" ->
      let* () = validate_target_type "keeper" request in
      let* name = require_target_id request in
      let status_args =
        `Assoc
          [
            ("name", `String name);
            ("fast", `Bool false);
            ("include_context", `Bool false);
            ("include_metrics_overview", `Bool true);
            ("include_memory_bank", `Bool false);
            ("include_history_tail", `Bool false);
            ("include_compaction_history", `Bool false);
          ]
      in
      let* before_status =
        dispatch_keeper_json ctx ~tool_name:"masc_keeper_status" ~args:status_args
      in
      let before_diagnostic =
        match U.member "diagnostic" before_status with
        | `Assoc _ as json -> json
        | _ -> `Null
      in
      let recoverable =
        match U.member "recoverable" before_diagnostic with
        | `Bool value -> value
        | _ -> false
      in
      if not recoverable then
        Ok
          (`Assoc
            [
              ("delegated_tool", `String "masc_keeper_recover");
              ( "result",
                `Assoc
                  [
                    ("recovered", `Bool false);
                    ("skipped_reason", `String "keeper is already healthy enough; recovery not required");
                    ("before", before_diagnostic);
                  ] );
            ])
      else
        let* down_result =
          dispatch_keeper_json ctx ~tool_name:"masc_keeper_down"
            ~args:(`Assoc [ ("name", `String name) ])
        in
        let* up_result =
          dispatch_keeper_json ctx ~tool_name:"masc_keeper_up"
            ~args:(`Assoc [ ("name", `String name) ])
        in
        let* after_status =
          dispatch_keeper_json ctx ~tool_name:"masc_keeper_status" ~args:status_args
        in
        let after_diagnostic =
          match U.member "diagnostic" after_status with
          | `Assoc _ as json -> json
          | _ -> `Null
        in
        let recovered, skipped_reason =
          keeper_recovery_outcome after_diagnostic
        in
        Ok
          (`Assoc
            [
              ("delegated_tool", `String "masc_keeper_recover");
              ( "result",
                `Assoc
                  [
                    ("recovered", `Bool recovered);
                    ( "skipped_reason",
                      match skipped_reason with
                      | Some reason -> `String reason
                      | None -> `Null );
                    ("before", before_diagnostic);
                    ("after", after_diagnostic);
                    ("down", down_result);
                    ("up", up_result);
                  ] );
            ])
  | "keeper_message" ->
      let* () = validate_target_type "keeper" request in
      let* name = require_target_id request in
      let message =
        match get_string_opt request.payload "message" with
        | Some value -> Ok value
        | None -> Error "payload.message is required"
      in
      let* message = message in
      let args =
        `Assoc
          [
            ("name", `String name);
            ("message", `String message);
          ]
      in
      let keeper_ctx : _ Tool_keeper.context =
        { config = ctx.config; sw = ctx.sw; clock = ctx.clock }
      in
      let* ok, body =
        match Tool_keeper.dispatch keeper_ctx ~name:"masc_keeper_msg" ~args with
        | Some (true, body) -> Ok (true, body)
        | Some (false, err) -> Error err
        | None -> Error "masc_keeper_msg dispatch unavailable"
      in
      let _ = ok in
      Ok
        (`Assoc
          [
            ("delegated_tool", `String "masc_keeper_msg");
            ("result", json_of_dispatch_output body);
          ])
  | "task_inject" ->
      let* () = validate_target_type "room" request in
      let title =
        match get_string_opt request.payload "title" with
        | Some value -> Ok value
        | None -> Error "payload.title is required"
      in
      let* title = title in
      let priority = get_int request.payload "priority" 2 in
      let description =
        get_string request.payload "description" "Injected by operator control plane"
      in
      let result = Room.add_task ctx.config ~title ~priority ~description in
      Ok
        (`Assoc
          [
            ("delegated_tool", `String "masc_add_task");
            ("result", `String result);
          ])
  | "" -> Error "action_type is required"
  | other -> Error (Printf.sprintf "unsupported action_type: %s" other)

let validate_request request =
  match request.action_type with
  | "broadcast" | "room_pause" | "room_resume" | "lodge_tick"
  | "team_turn" | "team_note"
  | "team_broadcast" | "team_task_inject" | "team_stop"
  | "keeper_message" | "keeper_probe" | "keeper_recover" | "task_inject" ->
      Ok ()
  | "" -> Error "action_type is required"
  | other -> Error (Printf.sprintf "unsupported action_type: %s" other)

let action_json ?actor_hint (ctx : 'a context) args =
  let request = action_request_of_args ?actor_hint ctx args in
  let* () = validate_request request in
  let delegated_tool = delegated_tool_for request.action_type in
  let trace_id = trace_id "ops" in
  let started_at = Unix.gettimeofday () in
  if confirm_required request.action_type then (
    let expires_at = iso_of_unix (Unix.gettimeofday () +. remote_confirm_ttl_seconds) in
    let entry =
      {
        token = generate_confirm_token ctx.config;
        trace_id;
        actor = request.actor;
        action_type = request.action_type;
        target_type = request.target_type;
        target_id = request.target_id;
        payload = request.payload;
        delegated_tool;
        created_at = Types.now_iso ();
        expires_at = Some expires_at;
      }
    in
    upsert_pending_confirm ctx.config entry;
    append_action_log ctx.config
      {
        trace_id;
        actor = request.actor;
        remote_session_id = ctx.mcp_session_id;
        remote_client_type = remote_client_type_of_context ctx;
        action_type = request.action_type;
        target_type = request.target_type;
        target_id = request.target_id;
        delegated_tool;
        confirmation_state = "preview";
        result_status = "ok";
        latency_ms = 0;
        created_at = Types.now_iso ();
      };
    Ok
      (json_ok
         [
           ("trace_id", `String trace_id);
           ("confirm_required", `Bool true);
           ("confirm_token", `String entry.token);
           ("preview", preview_of_action request);
           ("delegated_tool", `String delegated_tool);
           ("expires_at", `String expires_at);
         ]))
  else
    let* executed = execute_action ctx request in
    let latency_ms = int_of_float ((Unix.gettimeofday () -. started_at) *. 1000.0) in
    append_action_log ctx.config
      {
        trace_id;
        actor = request.actor;
        remote_session_id = ctx.mcp_session_id;
        remote_client_type = remote_client_type_of_context ctx;
        action_type = request.action_type;
        target_type = request.target_type;
        target_id = request.target_id;
        delegated_tool;
        confirmation_state = "immediate";
        result_status = "ok";
        latency_ms;
        created_at = Types.now_iso ();
      };
    Ok
      (json_ok
         [
           ("trace_id", `String trace_id);
           ("confirm_required", `Bool false);
           ("delegated_tool", `String delegated_tool);
           ("result", executed);
         ])

let confirm_json ?actor_hint (ctx : 'a context) args =
  let actor =
    normalized_actor ~context_actor:ctx.agent_name
      (match get_string_opt args "actor" with
      | Some actor -> Some actor
      | None -> actor_hint)
  in
  match get_string_opt args "confirm_token" with
  | None -> Error "confirm_token is required"
  | Some confirm_token -> (
      match
        raw_pending_confirms ctx.config
        |> List.find_opt (fun entry -> String.equal entry.token confirm_token)
      with
      | None -> Error "pending confirmation not found"
      | Some entry when pending_confirm_expired entry ->
          remove_pending_confirm ctx.config confirm_token;
          append_action_log ctx.config
            {
              trace_id = entry.trace_id;
              actor;
              remote_session_id = ctx.mcp_session_id;
              remote_client_type = remote_client_type_of_context ctx;
              action_type = entry.action_type;
              target_type = entry.target_type;
              target_id = entry.target_id;
              delegated_tool = entry.delegated_tool;
              confirmation_state = "expired";
              result_status = "error";
              latency_ms = 0;
              created_at = Types.now_iso ();
            };
          Error "pending confirmation expired"
      | Some entry when not (String.equal actor entry.actor) ->
          append_action_log ctx.config
            {
              trace_id = entry.trace_id;
              actor;
              remote_session_id = ctx.mcp_session_id;
              remote_client_type = remote_client_type_of_context ctx;
              action_type = entry.action_type;
              target_type = entry.target_type;
              target_id = entry.target_id;
              delegated_tool = entry.delegated_tool;
              confirmation_state = "denied";
              result_status = "error";
              latency_ms = 0;
              created_at = Types.now_iso ();
            };
          Error "actor is not allowed to confirm this action"
      | Some entry ->
          let started_at = Unix.gettimeofday () in
          let request =
            {
              actor = entry.actor;
              action_type = entry.action_type;
              target_type = entry.target_type;
              target_id = entry.target_id;
              payload = entry.payload;
            }
          in
          let* executed = execute_action ctx request in
          let latency_ms = int_of_float ((Unix.gettimeofday () -. started_at) *. 1000.0) in
          remove_pending_confirm ctx.config confirm_token;
          append_action_log ctx.config
            {
              trace_id = entry.trace_id;
              actor = entry.actor;
              remote_session_id = ctx.mcp_session_id;
              remote_client_type = remote_client_type_of_context ctx;
              action_type = entry.action_type;
              target_type = entry.target_type;
              target_id = entry.target_id;
              delegated_tool = entry.delegated_tool;
              confirmation_state = "confirmed";
              result_status = "ok";
              latency_ms;
              created_at = Types.now_iso ();
            };
          Ok
            (json_ok
               [
                 ("trace_id", `String entry.trace_id);
                 ("executed_action", pending_confirm_to_yojson entry);
                 ("delegated_tool_result", executed);
               ]))
