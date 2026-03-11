open Types
open Tool_args

type 'a context = {
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option;
}

type result = bool * string

let schema_properties entries = `Assoc entries

let json_string_of_result = function
  | Ok json -> (true, Yojson.Safe.to_string json)
  | Error message ->
      ( false,
        Yojson.Safe.to_string
          (`Assoc [ ("status", `String "error"); ("message", `String message) ]) )

let string_assoc key value = (key, `String value)

let schemas : tool_schema list =
  [
    {
      name = "masc_voice_speak";
      description =
        "Send text to the voice bridge for an agent. Uses the configured voice and may fall back to text_fallback when voice is unavailable.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              schema_properties
                [
                  ("agent_id", `Assoc [ ("type", `String "string") ]);
                  ("message", `Assoc [ ("type", `String "string") ]);
                  ("provider", `Assoc [ ("type", `String "string") ]);
                  ("priority", `Assoc [ ("type", `String "integer") ]);
                ] );
            ("required", `List [ `String "agent_id"; `String "message" ]);
          ];
    };
    {
      name = "masc_voice_session_start";
      description =
        "Start a voice session for an agent using the configured voice bridge.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              schema_properties
                [
                  ("agent_id", `Assoc [ ("type", `String "string") ]);
                  ("session_name", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "agent_id" ]);
          ];
    };
    {
      name = "masc_voice_session_end";
      description = "End the active voice session for an agent.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              schema_properties
                [ ("agent_id", `Assoc [ ("type", `String "string") ]) ] );
            ("required", `List [ `String "agent_id" ]);
          ];
    };
    {
      name = "masc_voice_sessions";
      description = "List active voice sessions from the voice bridge.";
      input_schema =
        `Assoc [ ("type", `String "object"); ("properties", `Assoc []) ];
    };
    {
      name = "masc_voice_agent";
      description = "Get the configured voice for an agent.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              schema_properties
                [ ("agent_id", `Assoc [ ("type", `String "string") ]) ] );
            ("required", `List [ `String "agent_id" ]);
          ];
    };
    {
      name = "masc_voice_transcript";
      description = "Get the current transcript payload from the voice bridge.";
      input_schema =
        `Assoc [ ("type", `String "object"); ("properties", `Assoc []) ];
    };
    {
      name = "masc_voice_conference_start";
      description =
        "Start a multi-agent voice conference for the given agents.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              schema_properties
                [
                  ( "agent_ids",
                    `Assoc
                      [
                        ("type", `String "array");
                        ("items", `Assoc [ ("type", `String "string") ]);
                      ] );
                  ("conference_name", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "agent_ids" ]);
          ];
    };
    {
      name = "masc_voice_conference_end";
      description =
        "End a multi-agent voice conference for the given agents.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              schema_properties
                [
                  ( "agent_ids",
                    `Assoc
                      [
                        ("type", `String "array");
                        ("items", `Assoc [ ("type", `String "string") ]);
                      ] );
                ] );
            ("required", `List [ `String "agent_ids" ]);
          ];
    };
  ]

let require_net_or_error (ctx : 'a context) =
  match ctx.net with
  | Some net -> Ok net
  | None -> Error "voice bridge requires net (server_state.net is None)"

let message_preview message =
  String.sub message 0 (min 50 (String.length message))

let text_fallback_json ~agent_id ~message =
  let voice = Voice_bridge.get_voice_for_agent agent_id in
  `Assoc
    [
      ("status", `String "text_fallback");
      string_assoc "agent_id" agent_id;
      string_assoc "voice" voice;
      string_assoc "message_preview" (message_preview message);
    ]

let handle_voice_speak (ctx : 'a context) args : result =
  let agent_id = get_string args "agent_id" "" |> String.trim in
  let message = get_string args "message" "" in
  let provider = get_string_opt args "provider" |> Option.map String.trim in
  let provider =
    match provider with
    | Some p when p <> "" -> Some p
    | _ -> None
  in
  let priority = max 1 (get_int args "priority" 1) in
  if agent_id = "" || String.trim message = "" then
    (false, "Error: agent_id and message are required")
  else
    match ctx.net with
    | Some net ->
        json_string_of_result
          (Voice_bridge.agent_speak ~sw:ctx.sw ~clock:ctx.clock ~net ~agent_id
             ~message ?provider ~priority ())
    | None -> (true, Yojson.Safe.to_string (text_fallback_json ~agent_id ~message))

let handle_voice_session_start (ctx : 'a context) args : result =
  let agent_id = get_string args "agent_id" "" |> String.trim in
  let session_name = get_string_opt args "session_name" |> Option.map String.trim in
  let session_name =
    match session_name with
    | Some name when name <> "" -> Some name
    | _ -> None
  in
  if agent_id = "" then
    (false, "Error: agent_id is required")
  else
    match require_net_or_error ctx with
    | Error message -> (false, message)
    | Ok net ->
        json_string_of_result
          (Voice_bridge.start_voice_session ~sw:ctx.sw ~clock:ctx.clock ~net
             ~agent_id ?session_name ())

let handle_voice_session_end (ctx : 'a context) args : result =
  let agent_id = get_string args "agent_id" "" |> String.trim in
  if agent_id = "" then
    (false, "Error: agent_id is required")
  else
    match ctx.net with
    | Some net ->
        json_string_of_result
          (Voice_bridge.end_voice_session ~sw:ctx.sw ~clock:ctx.clock ~net
             ~agent_id)
    | None ->
        ( true,
          Yojson.Safe.to_string
            (`Assoc
              [
                ("status", `String "skipped");
                ("reason", `String "voice bridge unavailable");
              ]) )

let handle_voice_sessions (ctx : 'a context) _args : result =
  match ctx.net with
  | Some net ->
      json_string_of_result
        (Voice_bridge.list_voice_sessions ~sw:ctx.sw ~clock:ctx.clock ~net)
  | None ->
      ( true,
        Yojson.Safe.to_string
          (`Assoc
            [
              ("sessions", `List []);
              ("status", `String "voice_server_unavailable");
            ]) )

let handle_voice_agent _ctx args : result =
  let agent_id = get_string args "agent_id" "" |> String.trim in
  if agent_id = "" then
    (false, "Error: agent_id is required")
  else
    json_string_of_result (Voice_bridge.get_agent_voice ~agent_id)

let handle_voice_transcript (ctx : 'a context) _args : result =
  match ctx.net with
  | Some net ->
      json_string_of_result
        (Voice_bridge.get_transcript ~sw:ctx.sw ~clock:ctx.clock ~net ())
  | None ->
      ( true,
        Yojson.Safe.to_string
          (`Assoc [ ("transcript", `List []); ("turn_count", `Int 0) ]) )

let handle_voice_conference_start (ctx : 'a context) args : result =
  let agent_ids =
    get_string_list args "agent_ids"
    |> List.map String.trim
    |> List.filter (fun item -> item <> "")
  in
  let conference_name = get_string_opt args "conference_name" |> Option.map String.trim in
  let conference_name =
    match conference_name with
    | Some name when name <> "" -> Some name
    | _ -> None
  in
  if agent_ids = [] then
    (false, "Error: agent_ids must include at least one agent")
  else
    match require_net_or_error ctx with
    | Error message -> (false, message)
    | Ok net ->
        json_string_of_result
          (Voice_bridge.start_conference ~sw:ctx.sw ~clock:ctx.clock ~net
             ~agent_ids ?conference_name ())

let handle_voice_conference_end (ctx : 'a context) args : result =
  let agent_ids =
    get_string_list args "agent_ids"
    |> List.map String.trim
    |> List.filter (fun item -> item <> "")
  in
  if agent_ids = [] then
    (false, "Error: agent_ids must include at least one agent")
  else
    match ctx.net with
    | Some net ->
        json_string_of_result
          (Voice_bridge.end_conference ~sw:ctx.sw ~clock:ctx.clock ~net
             ~agent_ids ())
    | None ->
        ( true,
          Yojson.Safe.to_string
            (`Assoc
              [
                ("ended", `Int 0);
                ("total", `Int (List.length agent_ids));
              ]) )

let dispatch (ctx : 'a context) ~name ~args : result option =
  match name with
  | "masc_voice_speak" -> Some (handle_voice_speak ctx args)
  | "masc_voice_session_start" -> Some (handle_voice_session_start ctx args)
  | "masc_voice_session_end" -> Some (handle_voice_session_end ctx args)
  | "masc_voice_sessions" -> Some (handle_voice_sessions ctx args)
  | "masc_voice_agent" -> Some (handle_voice_agent ctx args)
  | "masc_voice_transcript" -> Some (handle_voice_transcript ctx args)
  | "masc_voice_conference_start" -> Some (handle_voice_conference_start ctx args)
  | "masc_voice_conference_end" -> Some (handle_voice_conference_end ctx args)
  | _ -> None
