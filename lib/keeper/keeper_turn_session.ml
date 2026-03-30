(** Keeper_turn_session -- team-session integration for keepers.

    Auto-start, note-appending, and response-building for the keeper's
    linked team session.  Extracted from keeper_turn.ml. *)

open Keeper_types

type tool_result = Keeper_types.tool_result

let auto_team_session_spawn_profile = "generic_pair_v1"

let write_meta_logged config (meta : keeper_meta) =
  match write_meta config meta with
  | Ok () -> ()
  | Error msg ->
      Log.Keeper.error "write_meta failed: %s" msg

let _keeper_team_session_model (meta : keeper_meta) =
  match String.trim meta.runtime.usage.last_model_used with
  | value when value <> "" -> value
  | _ ->
      (match Oas_model_resolve.models_of_cascade_name meta.cascade_name with
       | model :: _ -> model
       | [] -> "default")

let keeper_team_session_note (meta : keeper_meta) (message : string) =
  Printf.sprintf
    "[keeper auto-team-session]\nkeeper=%s\nrequest=%s\nkeeper_goal=%s\ninstructions=%s"
    meta.name
    (short_preview ~max_len:240 message)
    (short_preview ~max_len:180 meta.goal)
    (short_preview ~max_len:220 meta.instructions)

let planner_spawn_prompt (meta : keeper_meta) (message : string) =
  Printf.sprintf
    "You are planner worker for keeper %s.\n\
     Incoming request:\n%s\n\n\
     Keeper goal:\n%s\n\n\
     Keeper instructions:\n%s\n\n\
     Leave exactly one non-empty planning note via masc_team_session_step that states:\n\
     - intended scope\n\
     - concrete success criteria\n\
     - first work split\n"
    meta.name message meta.goal
    (if String.trim meta.instructions = "" then "(none)" else meta.instructions)

let executor_spawn_prompt (meta : keeper_meta) (message : string) =
  Printf.sprintf
    "You are executor worker for keeper %s.\n\
     Incoming request:\n%s\n\n\
     Keeper goal:\n%s\n\n\
     Keeper instructions:\n%s\n\n\
     Leave exactly one non-empty execution note via masc_team_session_step that states:\n\
     - first concrete action\n\
     - likely files/surfaces/tools to inspect\n\
     - immediate blocker if any\n"
    meta.name message meta.goal
    (if String.trim meta.instructions = "" then "(none)" else meta.instructions)

let auto_team_session_spawn_batch (meta : keeper_meta) (message : string) =
  `List
    [
      `Assoc
        [
          ("spawn_prompt", `String (planner_spawn_prompt meta message));
          ("spawn_role", `String "planner");
          ("worker_class", `String "manager");
          ("worker_size", `String "xlg");
          ("spawn_timeout_seconds", `Int 120);
          ("spawn_selection_note", `String "keeper auto-team-session generic_pair_v1 planner");
        ];
      `Assoc
        [
          ("spawn_prompt", `String (executor_spawn_prompt meta message));
          ("spawn_role", `String "executor");
          ("worker_class", `String "executor");
          ("worker_size", `String "lg");
          ("spawn_timeout_seconds", `Int 120);
          ("spawn_selection_note", `String "keeper auto-team-session generic_pair_v1 executor");
        ];
    ]

let team_session_ctx_of_keeper (ctx : _ context) : _ Tool_team_session.context =
  {
    Tool_team_session.config = ctx.config;
    agent_name = ctx.agent_name;
    sw = ctx.sw;
    clock = ctx.clock;
    proc_mgr = ctx.proc_mgr;
    net = ctx.net;
  }

let dispatch_team_session (ctx : _ context) ~name ~args =
  match Tool_team_session.dispatch (team_session_ctx_of_keeper ctx) ~name ~args with
  | Some result -> result
  | None -> (false, Yojson.Safe.to_string (`Assoc [ ("status", `String "error"); ("message", `String "team session dispatch unavailable") ]))

let parse_result_json body =
  try
    let open Yojson.Safe.Util in
    let json = Yojson.Safe.from_string body in
    Ok (json |> member "result")
  with Yojson.Json_error err ->
    Error ("invalid json: " ^ err)

let session_id_of_result_json json =
  try Some Yojson.Safe.Util.(json |> member "session_id" |> to_string)
  with Yojson.Safe.Util.Type_error _ -> None

let string_option_to_json = function
  | Some value -> `String value
  | None -> `Null

let running_session_for_keeper config (meta : keeper_meta) =
  match meta.active_team_session_id with
  | None -> (meta, None)
  | Some session_id -> (
      match Team_session_store.load_session config session_id with
      | Some session when session.status = Team_session_types.Running ->
          (meta, Some session)
      | _ ->
          let updated =
            {
              meta with
              active_team_session_id = None;
              updated_at = now_iso ();
            }
          in
          write_meta_logged config updated;
          (updated, None))

let keeper_auto_team_session_response_json
    ~(meta : keeper_meta)
    ~(session : Team_session_types.session)
    ~(created : bool)
    ~(reused : bool)
    ?spawn_error
    () =
  `Assoc
    [
      ( "reply",
        `String
          (Printf.sprintf
             "Team session %s is ready. Use masc_team_session_status or masc_team_session_step."
             session.session_id) );
      ("mode", `String "team_session");
      ("keeper_name", `String meta.name);
      ("session_id", `String session.session_id);
      ("created", `Bool created);
      ("reused", `Bool reused);
      ("session_status", `String (Team_session_types.status_to_string session.status));
      ("spawn_profile", `String auto_team_session_spawn_profile);
      ("spawned_roles", `List [ `String "planner"; `String "executor" ]);
      ("spawn_error", string_option_to_json spawn_error);
      ("active_team_session_id", string_option_to_json meta.active_team_session_id);
      ("last_team_session_started_at", `String meta.last_team_session_started_at);
      ("team_session_start_count_total", `Int meta.team_session_start_count_total);
      ("next_read_tool", `String "masc_team_session_status");
      ("next_write_tool", `String "masc_team_session_step");
    ]

let start_keeper_auto_team_session (ctx : _ context) (meta : keeper_meta)
    (message : string) :
    (keeper_meta * Team_session_types.session * string option, string) result =
  let start_args =
    `Assoc
      [
        ("goal", `String message);
        ("duration_seconds", `Int 3600);
        ("execution_scope", `String meta.execution_scope);
        ("checkpoint_interval_sec", `Int 60);
        ("min_agents", `Int 2);
        ("auto_resume", `Bool true);
        ("report_formats", `List [ `String "markdown"; `String "json" ]);
        ("orchestration_mode", `String "assist");
        ("communication_mode", `String "hybrid");
        ("instruction_profile", `String "strict");
        ("alert_channel", `String "both");
        ( "model_cascade",
          `List
            (List.map (fun model -> `String model)
               (Team_session_types.dedup_strings
                  (_keeper_team_session_model meta
                  :: Oas_model_resolve.models_of_cascade_name meta.cascade_name))) );
        ( "agents",
          `List
            (Team_session_types.dedup_strings
               [ ctx.agent_name; meta.agent_name ]
            |> List.map (fun agent -> `String agent)) );
      ]
  in
  let start_ok, start_body =
    dispatch_team_session ctx ~name:"masc_team_session_start" ~args:start_args
  in
  if not start_ok then
    Error ("team session start failed: " ^ start_body)
  else
    match parse_result_json start_body with
    | Error msg -> Error ("team session start parse failed: " ^ msg)
    | Ok start_json -> (
        match session_id_of_result_json start_json with
        | None -> Error "team session start missing session_id"
        | Some session_id -> (
            match Team_session_store.load_session ctx.config session_id with
            | None -> Error ("team session not found after start: " ^ session_id)
            | Some session ->
                let updated_meta =
                  {
                    meta with
                    active_team_session_id = Some session_id;
                    last_team_session_started_at = now_iso ();
                    team_session_start_count_total =
                      meta.team_session_start_count_total + 1;
                    updated_at = now_iso ();
                  }
                in
                write_meta_logged ctx.config updated_meta;
                let note_args =
                  `Assoc
                    [
                      ("session_id", `String session_id);
                      ("turn_kind", `String "note");
                      ("message", `String (keeper_team_session_note updated_meta message));
                    ]
                in
                let note_ok, note_body =
                  dispatch_team_session ctx ~name:"masc_team_session_step"
                    ~args:note_args
                in
                if not note_ok then
                  Error ("team session note failed: " ^ note_body)
                else
                  let spawn_args =
                    `Assoc
                      [
                        ("session_id", `String session_id);
                        ("spawn_batch", auto_team_session_spawn_batch updated_meta message);
                      ]
                  in
                  let spawn_ok, spawn_body =
                    dispatch_team_session ctx ~name:"masc_team_session_step"
                      ~args:spawn_args
                  in
                  let spawn_error =
                    if spawn_ok then None else Some spawn_body
                  in
                  Ok (updated_meta, session, spawn_error)))

let append_keeper_auto_team_session_note (ctx : _ context) (meta : keeper_meta)
    (session : Team_session_types.session) (message : string) :
    (Team_session_types.session, string) result =
  let note_args =
    `Assoc
      [
        ("session_id", `String session.session_id);
        ("turn_kind", `String "note");
        ("message", `String (keeper_team_session_note meta message));
      ]
  in
  let ok, body =
    dispatch_team_session ctx ~name:"masc_team_session_step" ~args:note_args
  in
  if not ok then
    Error ("team session note failed: " ^ body)
  else
    match Team_session_store.load_session ctx.config session.session_id with
    | Some refreshed -> Ok refreshed
    | None -> Error ("team session disappeared after note: " ^ session.session_id)

(* Auto team_session interception removed — keeper decides autonomously
   via Agent.run() and tool calls. Stub kept for backward compatibility
   until keeper_turn_session.ml is fully cleaned up. *)
let maybe_handle_auto_team_session (_ctx : _ context) (meta : keeper_meta)
    (_message : string) :
    ((tool_result option * keeper_meta), string) result =
  Ok (None, meta)
