open Types

type 'a context = {
  config : Room.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
}

type result = bool * string

let get_string_opt args key =
  match Yojson.Safe.Util.member key args with
  | `String s ->
      let trimmed = String.trim s in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let get_bool args key default =
  match Yojson.Safe.Util.member key args with
  | `Bool value -> value
  | _ -> default

let json_string_of_result = function
  | Ok json -> (true, Yojson.Safe.to_string json)
  | Error message -> (false, Yojson.Safe.to_string (`Assoc [ ("status", `String "error"); ("message", `String message) ]))

let dispatch (ctx : 'a context) ~name ~args : result option =
  let control_ctx : 'a Operator_control.context =
    { config = ctx.config; agent_name = ctx.agent_name; sw = ctx.sw; clock = ctx.clock }
  in
  match name with
  | "masc_operator_snapshot" ->
      let actor = get_string_opt args "actor" in
      let include_messages = get_bool args "include_messages" true in
      let include_sessions = get_bool args "include_sessions" true in
      let include_keepers = get_bool args "include_keepers" true in
      Some
        ( true,
          Yojson.Safe.to_string
            (Operator_control.snapshot_json ?actor ~include_messages ~include_sessions
               ~include_keepers control_ctx) )
  | "masc_operator_action" ->
      Some (json_string_of_result (Operator_control.action_json control_ctx args))
  | "masc_operator_confirm" ->
      Some (json_string_of_result (Operator_control.confirm_json control_ctx args))
  | _ -> None

let schemas : tool_schema list =
  [
    {
      name = "masc_operator_snapshot";
      description =
        "Read unified operator state for room, team sessions, keepers, recent messages, and pending confirmations.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("actor", `Assoc [ ("type", `String "string") ]);
                  ("include_messages", `Assoc [ ("type", `String "boolean") ]);
                  ("include_sessions", `Assoc [ ("type", `String "boolean") ]);
                  ("include_keepers", `Assoc [ ("type", `String "boolean") ]);
                ] );
          ];
    };
    {
      name = "masc_operator_action";
      description =
        "Run a structured operator action against the room, a team session, or a keeper. Destructive actions return a confirm token first.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("actor", `Assoc [ ("type", `String "string") ]);
                  ( "action_type",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "broadcast";
                              `String "room_pause";
                              `String "room_resume";
                              `String "team_turn";
                              `String "team_stop";
                              `String "keeper_msg";
                              `String "task_inject";
                            ] );
                      ] );
                  ( "target_type",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [ `String "room"; `String "team_session"; `String "keeper" ] );
                      ] );
                  ("target_id", `Assoc [ ("type", `String "string") ]);
                  ("payload", `Assoc [ ("type", `String "object") ]);
                ] );
            ("required", `List [ `String "action_type"; `String "target_type"; `String "payload" ]);
          ];
    };
    {
      name = "masc_operator_confirm";
      description =
        "Confirm and execute a previously previewed operator action using its confirm token.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("actor", `Assoc [ ("type", `String "string") ]);
                  ("confirm_token", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "confirm_token" ]);
          ];
    };
  ]
