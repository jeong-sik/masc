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
        "Send text to the TTS layer for audio playback. Requires an active voice session (call masc_voice_session_start first). provider: optional, one of 'elevenlabs', 'openai_compat'. priority: 1=normal, higher=urgent.";
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
      description = "End the active voice session for an agent and release session resources. Use when the agent's voice interaction is complete or the session needs cleanup.";
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
    {
      name = "masc_voice_ping_pong";
      description =
        "Start a voice conversation loop with a keeper. Records speech, sends to keeper, speaks the response, repeats. Say 'stop' or '종료' to end.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              schema_properties
                [
                  ("name", `Assoc [ ("type", `String "string");
                    ("description", `String "Keeper name to talk to") ]);
                  ("max_turns", `Assoc [ ("type", `String "integer");
                    ("description", `String "Max conversation turns (default 50)") ]);
                  ("language_code", `Assoc [ ("type", `String "string");
                    ("description", `String "ISO language hint for STT, e.g. ko, en") ]);
                ] );
            ("required", `List [ `String "name" ]);
          ];
    };
  ]

let require_net_or_error (ctx : 'a context) =
  match ctx.net with
  | Some net -> Ok net
  | None -> Error "TTS service unavailable: server started without network. Restart masc-mcp with --http flag to enable voice tools."

(* --- Handler categories ---
   All handlers receive [ctx] for dispatch signature consistency.
   Category A (net required): speak, agent — call Voice_bridge over HTTP.
   Category B (local only):   session_start/end, sessions, conference_start/end
                               — use Keeper_voice_local / Voice_session_manager.
   Category C (stub):         transcript — STT service not yet integrated. *)

(* Category A: requires network for TTS endpoint *)
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

(* Category B: local session via Voice_session_manager *)
let handle_voice_session_start (_ctx : 'a context) args : result =
  let agent_id = get_string args "agent_id" "" |> String.trim in
  let voice = get_string_opt args "session_name" |> Option.map String.trim in
  let voice =
    match voice with
    | Some name when name <> "" -> Some name
    | _ -> None
  in
  if agent_id = "" then
    (false, "Error: agent_id is required")
  else
    let mgr = Keeper_voice_local.get_session_manager () in
    let session =
      Voice_session_manager.start_session mgr ~agent_id ?voice ()
    in
    (true, Yojson.Safe.to_string
      (Voice_session_manager.session_to_json session))

let handle_voice_session_end (_ctx : 'a context) args : result =
  let agent_id = get_string args "agent_id" "" |> String.trim in
  if agent_id = "" then
    (false, "Error: agent_id is required")
  else
    let mgr = Keeper_voice_local.get_session_manager () in
    let ended = Voice_session_manager.end_session mgr ~agent_id in
    (true, Yojson.Safe.to_string
      (`Assoc
        [ ("status", `String (if ended then "ended" else "no_active_session"));
          ("agent_id", `String agent_id) ]))

let handle_voice_sessions (_ctx : 'a context) _args : result =
  let mgr = Keeper_voice_local.get_session_manager () in
  let sessions = Voice_session_manager.list_sessions mgr in
  (true, Yojson.Safe.to_string
    (`Assoc
      [ ("session_count", `Int (List.length sessions));
        ("sessions",
          `List (List.map Voice_session_manager.session_to_json sessions)) ]))

(* Category A: reads agent voice config via Voice_bridge *)
let handle_voice_agent _ctx args : result =
  let agent_id = get_string args "agent_id" "" |> String.trim in
  if agent_id = "" then
    (false, "Error: agent_id is required")
  else
    json_string_of_result (Voice_bridge.get_agent_voice ~agent_id)

(* Category B: conference = batch start of local sessions for multiple agents.
   Each agent_id gets its own Voice_session_manager session; the "conference"
   is a convenience grouping, not a shared audio channel. *)
let handle_voice_conference_start (_ctx : 'a context) args : result =
  let agent_ids =
    get_string_list args "agent_ids"
    |> List.map String.trim
    |> List.filter (fun item -> item <> "")
  in
  if agent_ids = [] then
    (false, "Error: agent_ids must include at least one agent")
  else
    let mgr = Keeper_voice_local.get_session_manager () in
    let sessions = List.map (fun agent_id ->
      let session =
        Voice_session_manager.start_session mgr ~agent_id ()
      in
      Voice_session_manager.session_to_json session
    ) agent_ids in
    (true, Yojson.Safe.to_string
      (`Assoc
        [ ("status", `String "started");
          ("participant_count", `Int (List.length agent_ids));
          ("sessions", `List sessions) ]))

(* Category B: batch end — tears down each agent's session individually *)
let handle_voice_conference_end (_ctx : 'a context) args : result =
  let agent_ids =
    get_string_list args "agent_ids"
    |> List.map String.trim
    |> List.filter (fun item -> item <> "")
  in
  if agent_ids = [] then
    (false, "Error: agent_ids must include at least one agent")
  else
    let mgr = Keeper_voice_local.get_session_manager () in
    let ended = List.fold_left (fun count agent_id ->
      if Voice_session_manager.end_session mgr ~agent_id then count + 1
      else count
    ) 0 agent_ids in
    (true, Yojson.Safe.to_string
      (`Assoc
        [ ("ended", `Int ended);
          ("total", `Int (List.length agent_ids)) ]))

let dispatch (ctx : 'a context) ~name ~args : result option =
  match name with
  | "masc_voice_speak" -> Some (handle_voice_speak ctx args)
  | "masc_voice_session_start" -> Some (handle_voice_session_start ctx args)
  | "masc_voice_session_end" -> Some (handle_voice_session_end ctx args)
  | "masc_voice_sessions" -> Some (handle_voice_sessions ctx args)
  | "masc_voice_agent" -> Some (handle_voice_agent ctx args)
  | "masc_voice_conference_start" -> Some (handle_voice_conference_start ctx args)
  | "masc_voice_conference_end" -> Some (handle_voice_conference_end ctx args)
  | _ -> None

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let () =
  List.iter
    (fun (s : tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_voice
           ~input_schema:s.input_schema
           ()))
    schemas
