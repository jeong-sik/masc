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
        "Send text to the voice bridge for TTS playback. Requires an active voice session (call masc_voice_session_start first). provider: optional, one of 'elevenlabs', 'openai_compat'. priority: 1=normal, higher=urgent.";
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
        "Start a voice session for an agent. Call before masc_voice_speak. Requires voice_config.json with at least one TTS endpoint configured.";
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
      description = "End the active voice session for an agent and release bridge resources. Use when the agent's voice interaction is complete or the session needs cleanup.";
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
      description = "List active voice sessions. Use to check existing sessions before starting a new one or debugging.";
      input_schema =
        `Assoc [ ("type", `String "object"); ("properties", `Assoc []) ];
    };
    {
      name = "masc_voice_agent";
      description = "Get the configured voice settings (model, tone, language) for an agent. Use when verifying voice configuration before starting a session or debugging voice behavior.";
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
      description = "Get the current transcript (STT output) from the voice bridge. Requires an active voice session.";
      input_schema =
        `Assoc [ ("type", `String "object"); ("properties", `Assoc []) ];
    };
    {
      name = "masc_voice_conference_start";
      description =
        "Start a multi-agent voice conference. All agent_ids should have active voice sessions first (call masc_voice_session_start for each).";
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
        "End a multi-agent voice conference. Releases the shared channel; individual agent sessions remain active.";
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
  | None -> Error "Voice bridge unavailable: server started without network. Restart masc-mcp with --http flag to enable voice tools."

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
    match require_net_or_error ctx with
    | Error message -> (false, message)
    | Ok net ->
        json_string_of_result
          (Voice_bridge.agent_speak ~sw:ctx.sw ~clock:ctx.clock ~net ~agent_id
             ~message ?provider ~priority ())

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
    match require_net_or_error ctx with
    | Error message -> (false, message)
    | Ok net ->
        json_string_of_result
          (Voice_bridge.end_voice_session ~sw:ctx.sw ~clock:ctx.clock ~net
             ~agent_id)

let handle_voice_sessions (ctx : 'a context) _args : result =
  match require_net_or_error ctx with
  | Error message -> (false, message)
  | Ok net ->
      json_string_of_result
        (Voice_bridge.list_voice_sessions ~sw:ctx.sw ~clock:ctx.clock ~net)

let handle_voice_agent _ctx args : result =
  let agent_id = get_string args "agent_id" "" |> String.trim in
  if agent_id = "" then
    (false, "Error: agent_id is required")
  else
    json_string_of_result (Voice_bridge.get_agent_voice ~agent_id)

let handle_voice_transcript (ctx : 'a context) _args : result =
  match require_net_or_error ctx with
  | Error message -> (false, message)
  | Ok net ->
      json_string_of_result
        (Voice_bridge.get_transcript ~sw:ctx.sw ~clock:ctx.clock ~net ())

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
    match require_net_or_error ctx with
    | Error message -> (false, message)
    | Ok net ->
        json_string_of_result
          (Voice_bridge.end_conference ~sw:ctx.sw ~clock:ctx.clock ~net
             ~agent_ids ())

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
