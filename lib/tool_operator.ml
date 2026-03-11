open Types
open Tool_args

type 'a context = {
  config : Room.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
  mcp_session_id : string option;
}

type result = bool * string

let schema_properties entries = `Assoc entries

let strict_action_enums =
  [
    `String "broadcast";
    `String "room_pause";
    `String "room_resume";
    `String "lodge_tick";
    `String "team_note";
    `String "team_broadcast";
    `String "team_task_inject";
    `String "team_worker_spawn_batch";
    `String "team_stop";
    `String "keeper_message";
    `String "keeper_probe";
    `String "keeper_recover";
    `String "swarm_run_continue";
    `String "swarm_run_rerun";
    `String "swarm_run_abandon";
  ]

let legacy_action_alias_enums =
  [ `String "team_turn"; `String "keeper_msg"; `String "task_inject" ]

let target_type_enums =
  [ `String "room"; `String "team_session"; `String "keeper"; `String "swarm_run" ]

let snapshot_schema ~remote =
  {
    name = "masc_operator_snapshot";
    description =
      if remote then
        "Read the unified operator control-plane state. Use this when you need current room, session, keeper, message, and pending-confirm data before taking action."
      else
        "Read unified operator state for room, team sessions, keepers, recent messages, and pending confirmations. Use this before issuing control-plane actions.";
    input_schema =
      `Assoc
        [
          ("type", `String "object");
          ( "properties",
            schema_properties
              [
                ("actor", `Assoc [ ("type", `String "string") ]);
                ("view", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "summary"; `String "sessions"; `String "keepers"; `String "messages"; `String "full" ]) ]);
                ("include_messages", `Assoc [ ("type", `String "boolean") ]);
                ("include_sessions", `Assoc [ ("type", `String "boolean") ]);
                ("include_keepers", `Assoc [ ("type", `String "boolean") ]);
              ] );
        ];
  }

let digest_target_type_enums = [ `String "room"; `String "team_session" ]

let digest_schema ~remote =
  {
    name = "masc_operator_digest";
    description =
      if remote then
        "Read an intervention-oriented operator digest. Use this when you need room or team-session health, attention items, command-plane search or microarch signals, worker summaries, and recommended next actions before deciding how to intervene."
      else
        "Read a high-signal operator digest with intervention recommendations for the room or a specific team session. Use this when raw snapshot data is too low-level for fast supervision and you want translated command-plane search or microarch signals.";
    input_schema =
      `Assoc
        [
          ("type", `String "object");
          ( "properties",
            schema_properties
              [
                ("actor", `Assoc [ ("type", `String "string") ]);
                ( "target_type",
                  `Assoc
                    [
                      ("type", `String "string");
                      ("enum", `List digest_target_type_enums);
                    ] );
                ("target_id", `Assoc [ ("type", `String "string") ]);
                ("include_workers", `Assoc [ ("type", `String "boolean") ]);
              ] );
        ];
  }

let action_schema ~remote =
  let enum_values =
    if remote then strict_action_enums else strict_action_enums @ legacy_action_alias_enums
  in
  {
    name = "masc_operator_action";
    description =
      if remote then
        "Preview or run a structured operator action. Use this when you need to broadcast, steer a team session, pause a room, or message a keeper through the remote operator surface. For lodge_tick, the default is async accepted; set payload.wait=true to block for the full result."
      else
        "Run a structured operator action against the room, a team session, or a keeper. Use this when you need guided control with preview-confirm safety for disruptive actions. For lodge_tick, the default is async accepted; set payload.wait=true to block for the full result.";
    input_schema =
      `Assoc
        [
          ("type", `String "object");
          ( "properties",
            schema_properties
              [
                ("actor", `Assoc [ ("type", `String "string") ]);
                ( "action_type",
                  `Assoc
                    [
                      ("type", `String "string");
                      ("enum", `List enum_values);
                    ] );
                ( "target_type",
                  `Assoc
                    [
                      ("type", `String "string");
                      ("enum", `List target_type_enums);
                    ] );
                ("target_id", `Assoc [ ("type", `String "string") ]);
                ("payload", `Assoc [ ("type", `String "object") ]);
              ] );
            ("required", `List [ `String "action_type"; `String "payload" ]);
        ];
  }

let confirm_schema =
  {
    name = "masc_operator_confirm";
    description =
      "Confirm and execute a previously previewed operator action. Use this only after masc_operator_action returns confirm_required=true.";
    input_schema =
      `Assoc
        [
          ("type", `String "object");
          ( "properties",
            schema_properties
              [
                ("actor", `Assoc [ ("type", `String "string") ]);
                ("confirm_token", `Assoc [ ("type", `String "string") ]);
                ( "decision",
                  `Assoc
                    [
                      ("type", `String "string");
                      ("enum", `List [ `String "confirm"; `String "deny" ]);
                    ] );
              ] );
          ("required", `List [ `String "confirm_token" ]);
        ];
  }

let json_string_of_result = function
  | Ok json -> (true, Yojson.Safe.to_string json)
  | Error message -> (false, Yojson.Safe.to_string (`Assoc [ ("status", `String "error"); ("message", `String message) ]))

let dispatch (ctx : 'a context) ~name ~args : result option =
  let control_ctx : 'a Operator_control.context =
    {
      config = ctx.config;
      agent_name = ctx.agent_name;
      sw = ctx.sw;
      clock = ctx.clock;
      proc_mgr = ctx.proc_mgr;
      mcp_session_id = ctx.mcp_session_id;
    }
  in
  match name with
  | "masc_operator_snapshot" ->
      let actor = get_string_opt args "actor" in
      let view = get_string_opt args "view" in
      let include_messages = get_bool args "include_messages" true in
      let include_sessions = get_bool args "include_sessions" true in
      let include_keepers = get_bool args "include_keepers" true in
      Some
        ( true,
          Yojson.Safe.to_string
            (Operator_control.snapshot_json ?actor ?view ~include_messages ~include_sessions
               ~include_keepers control_ctx) )
  | "masc_operator_digest" ->
      let actor = get_string_opt args "actor" in
      let target_type = get_string_opt args "target_type" in
      let target_id = get_string_opt args "target_id" in
      let include_workers = get_bool args "include_workers" true in
      Some
        (json_string_of_result
           (Operator_control.digest_json ?actor ?target_type ?target_id
              ~include_workers control_ctx))
  | "masc_operator_action" ->
      Some (json_string_of_result (Operator_control.action_json control_ctx args))
  | "masc_operator_confirm" ->
      Some (json_string_of_result (Operator_control.confirm_json control_ctx args))
  | _ -> None

let schemas : tool_schema list =
  [
    snapshot_schema ~remote:false;
    digest_schema ~remote:false;
    action_schema ~remote:false;
    confirm_schema;
  ]

let remote_schemas : tool_schema list =
  [
    snapshot_schema ~remote:true;
    digest_schema ~remote:true;
    action_schema ~remote:true;
    confirm_schema;
  ]

let remote_tool_names : string list =
  List.map (fun (schema : tool_schema) -> schema.name) remote_schemas
