module U = Yojson.Safe.Util

let ( let* ) = Result.bind

type 'a context = {
  config : Room.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
}

type pending_confirm = {
  token : string;
  actor : string;
  action_type : string;
  target_type : string;
  target_id : string option;
  payload : Yojson.Safe.t;
  delegated_tool : string;
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

let preview_of_pending_confirm (entry : pending_confirm) =
  `Assoc
    [
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
      ("actor", `String entry.actor);
      ("action_type", `String entry.action_type);
      ("target_type", `String entry.target_type);
      ("target_id", string_option_to_json entry.target_id);
      ("payload", entry.payload);
      ("delegated_tool", `String entry.delegated_tool);
      ("created_at", `String entry.created_at);
      ("preview", preview_of_pending_confirm entry);
    ]

let pending_confirm_of_yojson json =
  try
    let token = json |> U.member "token" |> U.to_string in
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
    Ok
      {
        token;
        actor;
        action_type;
        target_type;
        target_id;
        payload;
        delegated_tool;
        created_at;
      }
  with U.Type_error (msg, _) | Failure msg -> Error msg

let read_pending_confirms config =
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

let write_pending_confirms config entries =
  Room_utils.write_json config (pending_confirms_path config)
    (`List (List.map pending_confirm_to_yojson entries))

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
  let rows =
    read_pending_confirms config
    |> List.filter (fun entry ->
           match actor_filter with
           | None -> true
           | Some value -> String.equal value entry.actor)
    |> List.sort (fun a b -> String.compare b.created_at a.created_at)
  in
  `List (List.map pending_confirm_to_yojson rows)

let available_actions_json =
  `List
    [
      `Assoc
        [
          ("action_type", `String "broadcast");
          ("target_type", `String "room");
          ("confirm_required", `Bool false);
        ];
      `Assoc
        [
          ("action_type", `String "room_pause");
          ("target_type", `String "room");
          ("confirm_required", `Bool true);
        ];
      `Assoc
        [
          ("action_type", `String "room_resume");
          ("target_type", `String "room");
          ("confirm_required", `Bool false);
        ];
      `Assoc
        [
          ("action_type", `String "team_turn");
          ("target_type", `String "team_session");
          ("confirm_required", `Bool false);
        ];
      `Assoc
        [
          ("action_type", `String "team_stop");
          ("target_type", `String "team_session");
          ("confirm_required", `Bool true);
        ];
      `Assoc
        [
          ("action_type", `String "keeper_msg");
          ("target_type", `String "keeper");
          ("confirm_required", `Bool false);
        ];
      `Assoc
        [
          ("action_type", `String "task_inject");
          ("target_type", `String "room");
          ("confirm_required", `Bool true);
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

let snapshot_json ?actor ?(include_messages = true) ?(include_sessions = true)
    ?(include_keepers = true) (ctx : 'a context) : Yojson.Safe.t =
  let config = ctx.config in
  let initialized = Room.is_initialized config in
  `Assoc
    [
      ("room", room_json config);
      ( "sessions",
        if initialized && include_sessions then sessions_json config
        else `Assoc [ ("count", `Int 0); ("items", `List []) ] );
      ( "keepers",
        if initialized && include_keepers then keepers_json config
        else `Assoc [ ("count", `Int 0); ("items", `List []) ] );
      ("recent_messages", if initialized && include_messages then recent_messages_json config else `List []);
      ("pending_confirms", pending_confirms_json ?actor config);
      ("available_actions", available_actions_json);
    ]

type action_request = {
  actor : string;
  action_type : string;
  target_type : string;
  target_id : string option;
  payload : Yojson.Safe.t;
}

let generate_confirm_token (request : action_request) =
  let entropy =
    Printf.sprintf "%s|%s|%s|%d|%.6f|%d"
      request.actor request.action_type
      (Yojson.Safe.to_string request.payload)
      (Unix.getpid ()) (Unix.gettimeofday ()) (Random.bits ())
  in
  let digest = Digestif.SHA256.(digest_string entropy |> to_hex) in
  "opc_" ^ String.sub digest 0 32

let action_request_of_args ?actor_hint ctx args =
  let actor =
    normalized_actor ~context_actor:ctx.agent_name
      (match get_string_opt args "actor" with
      | Some actor -> Some actor
      | None -> actor_hint)
  in
  {
    actor;
    action_type = get_string args "action_type" "" |> String.trim |> String.lowercase_ascii;
    target_type = get_string args "target_type" "" |> String.trim |> String.lowercase_ascii;
    target_id = get_string_opt args "target_id";
    payload = get_payload args;
  }

let delegated_tool_for action_type =
  match action_type with
  | "broadcast" -> "masc_broadcast"
  | "room_pause" -> "masc_pause"
  | "room_resume" -> "masc_resume"
  | "team_turn" -> "masc_team_session_turn"
  | "team_stop" -> "masc_team_session_stop"
  | "keeper_msg" -> "masc_keeper_msg"
  | "task_inject" -> "masc_add_task"
  | _ -> "unknown"

let confirm_required = function
  | "room_pause" | "team_stop" | "task_inject" -> true
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
  | "keeper_msg" ->
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
  | "broadcast" | "room_pause" | "room_resume" | "team_turn" | "team_stop"
  | "keeper_msg" | "task_inject" ->
      Ok ()
  | "" -> Error "action_type is required"
  | other -> Error (Printf.sprintf "unsupported action_type: %s" other)

let action_json ?actor_hint (ctx : 'a context) args =
  let request = action_request_of_args ?actor_hint ctx args in
  let* () = validate_request request in
  let delegated_tool = delegated_tool_for request.action_type in
  if confirm_required request.action_type then (
    let entry =
      {
        token = generate_confirm_token request;
        actor = request.actor;
        action_type = request.action_type;
        target_type = request.target_type;
        target_id = request.target_id;
        payload = request.payload;
        delegated_tool;
        created_at = Types.now_iso ();
      }
    in
    upsert_pending_confirm ctx.config entry;
    Ok
      (json_ok
         [
           ("confirm_required", `Bool true);
           ("confirm_token", `String entry.token);
           ("preview", preview_of_action request);
           ("delegated_tool", `String delegated_tool);
         ]))
  else
    let* executed = execute_action ctx request in
    Ok
      (json_ok
         [
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
        read_pending_confirms ctx.config
        |> List.find_opt (fun entry -> String.equal entry.token confirm_token)
      with
      | None -> Error "pending confirmation not found"
      | Some entry when not (String.equal actor entry.actor) ->
          Error "actor is not allowed to confirm this action"
      | Some entry ->
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
          remove_pending_confirm ctx.config confirm_token;
          Ok
            (json_ok
               [
                 ("executed_action", pending_confirm_to_yojson entry);
                 ("delegated_tool_result", executed);
               ]))
