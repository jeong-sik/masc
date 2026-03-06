(** MCP tools for long-running team sessions (1h orchestration). *)

open Types

type 'a context = {
  config : Room.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
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

let get_float_opt args key =
  match Yojson.Safe.Util.member key args with
  | `Float v -> Some v
  | `Int n -> Some (float_of_int n)
  | `Intlit s -> (try Some (float_of_string s) with _ -> None)
  | _ -> None

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
  | "strict_local_only" -> Team_session_types.Fallback_none
  | "task_only" -> Team_session_types.Fallback_task_only
  | "local_first_conditional" -> Team_session_types.Fallback_cascade_then_task
  | "cloud_first" -> Team_session_types.Fallback_cascade_then_task
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

let get_agent_names args key =
  match Yojson.Safe.Util.member key args with
  | `List xs ->
      xs
      |> List.filter_map (function
             | `String s ->
                 let t = String.trim s in
                 if t = "" then None else Some t
             | `Assoc fields -> (
                 match List.assoc_opt "name" fields with
                 | Some (`String s) ->
                     let t = String.trim s in
                     if t = "" then None else Some t
                 | _ -> None)
             | _ -> None)
  | _ -> []

let parse_turn_kind args =
  let raw = get_string args "turn_kind" "note" |> String.trim |> String.lowercase_ascii in
  match Team_session_types.turn_kind_of_string raw with
  | Some k -> Ok k
  | None ->
      Error
        "invalid turn_kind (allowed: note|broadcast|portal|task|checkpoint)"

let parse_turn_kind_opt args =
  match get_string_opt args "turn_kind" with
  | None -> Ok None
  | Some raw -> (
      match Team_session_types.turn_kind_of_string (String.lowercase_ascii raw) with
      | Some k -> Ok (Some k)
      | None ->
          Error
            "invalid turn_kind (allowed: note|broadcast|portal|task|checkpoint)")

let parse_proof_level args =
  let raw =
    get_string args "proof_level" "standard"
    |> String.trim |> String.lowercase_ascii
  in
  Team_session_types.proof_level_of_string raw

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
    let duration_seconds =
      let raw_seconds = get_int args "duration_seconds" 0 in
      if raw_seconds > 0 then
        raw_seconds
      else
        let duration_minutes = get_int args "duration_minutes" 60 in
        max 1 duration_minutes * 60
    in
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
    let agents = get_agent_names args "agents" in
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

let handle_turn ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () -> (
          match parse_turn_kind args with
          | Error e -> (false, json_error e)
          | Ok turn_kind ->
              let message = get_string_opt args "message" in
              let target_agent = get_string_opt args "target_agent" in
              let task_title = get_string_opt args "task_title" in
              let task_description = get_string_opt args "task_description" in
              let task_priority = get_int args "task_priority" 3 in
              (match
                 Team_session_engine_eio.record_turn ~config:ctx.config
                   ~session_id ~actor:ctx.agent_name ~turn_kind ~message
                   ~target_agent ~task_title ~task_description ~task_priority
               with
              | Ok json -> (true, json_ok [ ("result", json) ])
              | Error e -> (false, json_error e))))

let int_opt_to_json = function Some n -> `Int n | None -> `Null
let float_opt_to_json = function Some v -> `Float v | None -> `Null

let truncate_for_event ?(max_len = 320) (s : string) =
  if String.length s <= max_len then
    s
  else
    String.sub s 0 max_len ^ "..."

let derived_llama_runtime_actor ~session_id ~prompt =
  let digest = Digest.string (session_id ^ "\n" ^ prompt) |> Digest.to_hex in
  Printf.sprintf "llama-local-%s" (String.sub digest 0 8)

let ensure_session_actor config session_id actor_name =
  match Team_session_store.update_session config session_id (fun session ->
            let agent_names =
              Team_session_types.dedup_strings (session.agent_names @ [ actor_name ])
            in
            { session with agent_names; updated_at_iso = Types.now_iso () })
  with
  | Ok updated ->
      Team_session_store.append_event config session_id
        ~event_type:"session_agent_attached"
        ~detail:
          (`Assoc
            [
              ("actor", `String actor_name);
              ("agent_count", `Int (List.length updated.agent_names));
              ("ts_iso", `String (Types.now_iso ()));
            ]);
      Ok ()
  | Error e -> Error e

let extract_vote_id (text : string) =
  let re = Str.regexp "vote-[0-9-]+-[0-9]+" in
  try
    let _ = Str.search_forward re text 0 in
    Some (Str.matched_string text)
  with Not_found -> None

let status_of_engine_status_json (json : Yojson.Safe.t) =
  match Yojson.Safe.Util.member "session" json |> Yojson.Safe.Util.member "status" with
  | `String s -> s
  | _ -> "unknown"

let handle_step ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () ->
          let spawn_agent_opt = get_string_opt args "spawn_agent" in
          let spawn_prompt_opt = get_string_opt args "spawn_prompt" in
          let has_spawn = Option.is_some spawn_agent_opt || Option.is_some spawn_prompt_opt in
          let turn_kind_result =
            if has_spawn then parse_turn_kind_opt args
            else
              match parse_turn_kind args with
              | Ok kind -> Ok (Some kind)
              | Error e -> Error e
          in
          match turn_kind_result with
          | Error e -> (false, json_error e)
          | Ok turn_kind_opt ->
              let actor =
                match get_string_opt args "actor" with
                | Some a -> a
                | None -> ctx.agent_name
              in
              let base_message = get_string_opt args "message" in
              let target_agent = get_string_opt args "target_agent" in
              let task_title = get_string_opt args "task_title" in
              let task_description = get_string_opt args "task_description" in
              let task_priority = get_int args "task_priority" 3 in
              let spawn_model_opt = get_string_opt args "spawn_model" in
              let spawn_role_opt = get_string_opt args "spawn_role" in
              let spawn_selection_note_opt =
                get_string_opt args "spawn_selection_note"
              in
              let spawn_timeout_seconds = get_int args "spawn_timeout_seconds" 300 in
              let append_spawn_event ?spawn_agent ?runtime_actor ?spawn_role
                  ?spawn_model ?spawn_selection_note ~success ?exit_code
                  ?elapsed_ms ?output_preview ?error () =
                let detail =
                  `Assoc
                    [
                      ("actor", `String actor);
                      ( "spawn_agent",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          spawn_agent );
                      ( "runtime_actor",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          runtime_actor );
                      ( "spawn_role",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          spawn_role );
                      ( "spawn_model",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          spawn_model );
                      ( "spawn_selection_note",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          spawn_selection_note );
                      ("success", `Bool success);
                      ("exit_code", int_opt_to_json exit_code);
                      ("elapsed_ms", int_opt_to_json elapsed_ms);
                      ( "output_preview",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          output_preview );
                      ("error", Option.fold ~none:`Null ~some:(fun s -> `String s) error);
                      ("ts_iso", `String (Types.now_iso ()));
                    ]
                in
                Team_session_store.append_event ctx.config session_id
                  ~event_type:"team_step_spawn" ~detail
              in
              let spawn_result_json =
                match (spawn_agent_opt, spawn_prompt_opt) with
                | None, None -> None
                | Some _, None | None, Some _ ->
                    let msg =
                      "spawn_agent and spawn_prompt must be provided together"
                    in
                    append_spawn_event ~success:false ~error:msg ();
                    Some (`Assoc [ ("error", `String msg) ])
                | Some spawn_agent, Some spawn_prompt ->
                    let runtime_agent_name =
                      if String.equal spawn_agent "llama" then
                        Some
                          (derived_llama_runtime_actor ~session_id
                             ~prompt:spawn_prompt)
                      else
                        None
                    in
                    let runtime_model =
                      if String.equal spawn_agent "llama" then
                        match spawn_model_opt with
                        | None ->
                            Error
                              "spawn_model is required when spawn_agent=llama"
                        | Some model_name -> (
                            match
                              Llm_client.model_spec_of_string
                                ("llama:" ^ model_name)
                            with
                            | Ok spec -> Ok spec
                            | Error err ->
                                Error ("invalid spawn_model: " ^ err))
                      else
                        Ok (Llm_client.ollama_glm)
                    in
                    let prep_error =
                      match runtime_agent_name with
                      | Some worker_actor ->
                          ensure_session_actor ctx.config session_id worker_actor
                      | None -> Ok ()
                    in
                    let spawn_error =
                      match prep_error with
                      | Error msg -> Some msg
                      | Ok () -> (
                          match runtime_model with
                          | Error msg -> Some msg
                          | Ok _ -> None)
                    in
                    (match spawn_error with
                     | Some msg ->
                         append_spawn_event ~spawn_agent ?runtime_actor:runtime_agent_name
                           ?spawn_role:spawn_role_opt ?spawn_model:spawn_model_opt
                           ?spawn_selection_note:spawn_selection_note_opt
                           ~success:false ~error:msg ();
                         Some (`Assoc [ ("error", `String msg) ])
                     | None -> (
                         match ctx.proc_mgr with
                         | None ->
                             let msg =
                               "process manager unavailable for team step spawn"
                             in
                             append_spawn_event ~spawn_agent
                               ?runtime_actor:runtime_agent_name
                               ?spawn_role:spawn_role_opt
                               ?spawn_model:spawn_model_opt
                               ?spawn_selection_note:spawn_selection_note_opt
                               ~success:false ~error:msg ();
                             Some (`Assoc [ ("error", `String msg) ])
                         | Some pm ->
                             let spawn_result =
                               Spawn_eio.spawn ~sw:ctx.sw ~proc_mgr:pm
                                 ~agent_name:spawn_agent ~prompt:spawn_prompt
                                 ~timeout_seconds:spawn_timeout_seconds
                                 ~room_config:ctx.config
                                 ?runtime_agent_name
                                 ~runtime_model:(Result.get_ok runtime_model)
                                 ?runtime_role:spawn_role_opt
                                 ?runtime_selection_note:spawn_selection_note_opt
                                 ~runtime_session_id:session_id ()
                             in
                             let output_preview =
                               truncate_for_event spawn_result.output
                             in
                             append_spawn_event ~spawn_agent
                               ?runtime_actor:runtime_agent_name
                               ?spawn_role:spawn_role_opt
                               ?spawn_model:spawn_model_opt
                               ?spawn_selection_note:spawn_selection_note_opt
                               ~success:spawn_result.success
                               ~exit_code:spawn_result.exit_code
                               ~elapsed_ms:spawn_result.elapsed_ms
                               ~output_preview ();
                             Some
                               (`Assoc
                                 [
                                   ("agent", `String spawn_agent);
                                   ( "runtime_actor",
                                     Option.fold ~none:`Null
                                       ~some:(fun s -> `String s)
                                       runtime_agent_name );
                                   ( "spawn_role",
                                     Option.fold ~none:`Null
                                       ~some:(fun s -> `String s)
                                       spawn_role_opt );
                                   ( "spawn_model",
                                     Option.fold ~none:`Null
                                       ~some:(fun s -> `String s)
                                       spawn_model_opt );
                                   ( "spawn_selection_note",
                                     Option.fold ~none:`Null
                                       ~some:(fun s -> `String s)
                                       spawn_selection_note_opt );
                                   ("success", `Bool spawn_result.success);
                                   ("exit_code", `Int spawn_result.exit_code);
                                   ("elapsed_ms", `Int spawn_result.elapsed_ms);
                                   ("output_preview", `String output_preview);
                                   ( "input_tokens",
                                     int_opt_to_json spawn_result.input_tokens );
                                   ( "output_tokens",
                                     int_opt_to_json spawn_result.output_tokens );
                                   ( "cache_creation_tokens",
                                     int_opt_to_json
                                       spawn_result.cache_creation_tokens );
                                   ( "cache_read_tokens",
                                     int_opt_to_json
                                       spawn_result.cache_read_tokens );
                                   ("cost_usd", float_opt_to_json spawn_result.cost_usd);
                                 ])))
              in
              let spawn_error =
                match spawn_result_json with
                | Some (`Assoc fields) -> (
                    match List.assoc_opt "error" fields with
                    | Some (`String e) when String.trim e <> "" -> Some e
                    | _ -> None)
                | _ -> None
              in
              match spawn_error with
              | Some e -> (false, json_error e)
              | None ->
                  let turn_json_result =
                    match turn_kind_opt with
                    | None -> Ok None
                    | Some turn_kind ->
                        Team_session_engine_eio.record_turn ~config:ctx.config
                          ~session_id ~actor ~turn_kind ~message:base_message
                          ~target_agent ~task_title ~task_description
                          ~task_priority
                        |> Result.map Option.some
                  in
                  match turn_json_result with
                  | Error e -> (false, json_error e)
                  | Ok turn_json ->
                      let vote_result_json =
                        match get_string_opt args "vote_topic" with
                        | None -> None
                        | Some vote_topic ->
                            let vote_options = get_string_list args "vote_options" in
                            if List.length vote_options < 2 then
                              Some
                                (`Assoc
                                  [
                                    ("error", `String "vote_options requires at least 2 items");
                                  ])
                            else
                              let required_votes = get_int args "vote_required_votes" 2 in
                              let vote_create_msg =
                                Room.vote_create ctx.config ~proposer:actor
                                  ~topic:vote_topic ~options:vote_options
                                  ~required_votes
                              in
                              let vote_id = extract_vote_id vote_create_msg in
                              Team_session_store.append_event ctx.config session_id
                                ~event_type:"team_vote_created"
                                ~detail:
                                  (`Assoc
                                    [
                                      ("actor", `String actor);
                                      ("topic", `String vote_topic);
                                      ("required_votes", `Int required_votes);
                                      ("options", `List (List.map (fun o -> `String o) vote_options));
                                      ("vote_id", Option.fold ~none:`Null ~some:(fun s -> `String s) vote_id);
                                      ("result", `String vote_create_msg);
                                      ("ts_iso", `String (Types.now_iso ()));
                                    ]);
                              let cast_json =
                                match (vote_id, get_string_opt args "vote_choice") with
                                | Some vid, Some choice ->
                                    let cast_msg =
                                      Room.vote_cast ctx.config ~agent_name:actor
                                        ~vote_id:vid ~choice
                                    in
                                    Team_session_store.append_event ctx.config session_id
                                      ~event_type:"team_vote_cast"
                                      ~detail:
                                        (`Assoc
                                          [
                                            ("actor", `String actor);
                                            ("vote_id", `String vid);
                                            ("choice", `String choice);
                                            ("result", `String cast_msg);
                                            ("ts_iso", `String (Types.now_iso ()));
                                          ]);
                                    Some (`Assoc [ ("vote_id", `String vid); ("choice", `String choice); ("result", `String cast_msg) ])
                                | _ -> None
                              in
                              Some
                                (`Assoc
                                  [
                                    ("created", `String vote_create_msg);
                                    ("vote_id", Option.fold ~none:`Null ~some:(fun s -> `String s) vote_id);
                                    ("cast", Option.fold ~none:`Null ~some:(fun j -> j) cast_json);
                                  ])
                      in
                      let vote_error =
                        match vote_result_json with
                        | Some (`Assoc fields) -> (
                            match List.assoc_opt "error" fields with
                            | Some (`String e) when String.trim e <> "" -> Some e
                            | _ -> None)
                        | _ -> None
                      in
                      match vote_error with
                      | Some e -> (false, json_error e)
                      | None ->
                          let run_json =
                            match get_string_opt args "run_task_id" with
                            | None -> None
                            | Some run_task_id ->
                                let run_agent = actor in
                                let init_json =
                                  match
                                    Run_eio.init ctx.config ~task_id:run_task_id
                                      ~agent_name:(Some run_agent)
                                  with
                                  | Ok run -> `Assoc [ ("status", `String "initialized"); ("run", Run_eio.run_record_to_json run) ]
                                  | Error e -> `Assoc [ ("status", `String "init_failed"); ("error", `String e) ]
                                in
                                let note_json =
                                  match get_string_opt args "run_note" with
                                  | None -> `Null
                                  | Some note -> (
                                      match Run_eio.append_log ctx.config ~task_id:run_task_id ~note with
                                      | Ok entry -> `Assoc [ ("status", `String "ok"); ("entry", Run_eio.log_entry_to_json entry) ]
                                      | Error e -> `Assoc [ ("status", `String "error"); ("message", `String e) ])
                                in
                                let deliverable_json =
                                  match get_string_opt args "run_deliverable" with
                                  | None -> `Null
                                  | Some content -> (
                                      match
                                        Run_eio.set_deliverable ctx.config
                                          ~task_id:run_task_id ~content
                                      with
                                      | Ok run ->
                                          Team_session_store.append_event ctx.config
                                            session_id
                                            ~event_type:"team_run_deliverable"
                                            ~detail:
                                              (`Assoc
                                                [
                                                  ("actor", `String actor);
                                                  ("run_task_id", `String run_task_id);
                                                  ("deliverable_preview", `String (truncate_for_event content));
                                                  ("ts_iso", `String (Types.now_iso ()));
                                                ]);
                                          `Assoc [ ("status", `String "ok"); ("run", Run_eio.run_record_to_json run) ]
                                      | Error e ->
                                          `Assoc [ ("status", `String "error"); ("message", `String e) ])
                                in
                                Some
                                  (`Assoc
                                    [
                                      ("task_id", `String run_task_id);
                                      ("init", init_json);
                                      ("note", note_json);
                                      ("deliverable", deliverable_json);
                                    ])
                          in
                          let response =
                            `Assoc
                              [
                                ("session_id", `String session_id);
                                ("turn", Option.value ~default:`Null turn_json);
                                ("spawn", Option.fold ~none:`Null ~some:(fun j -> j) spawn_result_json);
                                ("vote", Option.fold ~none:`Null ~some:(fun j -> j) vote_result_json);
                                ("run", Option.fold ~none:`Null ~some:(fun j -> j) run_json);
                              ]
                          in
                          (true, json_ok [ ("result", response) ]))

let handle_finalize ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () ->
          let reason = get_string args "reason" "finalize" in
          let wait_timeout_sec = get_int args "wait_timeout_sec" 45 in
          let generate_report = get_bool args "generate_report" true in
          let generate_proof = get_bool args "generate_proof" true in
          let proof_level = parse_proof_level args in
          match
            Team_session_engine_eio.stop_session ~config:ctx.config ~session_id
              ~reason ~generate_report
          with
          | Error e -> (false, json_error e)
          | Ok stop_json ->
              let rec wait_terminal remaining last_status =
                if remaining <= 0 then
                  Error
                    (Printf.sprintf
                       "timeout waiting for terminal state (last_status=%s)"
                       last_status)
                else
                  match
                    Team_session_engine_eio.status_session ~config:ctx.config
                      ~session_id
                  with
                  | Error e -> Error e
                  | Ok status_json ->
                      let status = status_of_engine_status_json status_json in
                      if String.equal status "running" then (
                        Eio.Time.sleep ctx.clock 0.2;
                        wait_terminal (remaining - 1) status)
                      else
                        Ok (status, status_json)
              in
              let polls = max 1 (wait_timeout_sec * 5) in
              match wait_terminal polls "running" with
              | Error e -> (false, json_error e)
              | Ok (terminal_status, status_json) ->
                  let report_json =
                    if generate_report then
                      match
                        Team_session_engine_eio.generate_report ~config:ctx.config
                          ~session_id ~force_regenerate:false
                      with
                      | Ok json ->
                          `Assoc [ ("status", `String "ok"); ("result", json) ]
                      | Error e ->
                          `Assoc
                            [ ("status", `String "error"); ("message", `String e) ]
                    else
                      `Null
                  in
                  let report_error =
                    match report_json with
                    | `Assoc fields -> (
                        match List.assoc_opt "status" fields with
                        | Some (`String "error") -> (
                            match List.assoc_opt "message" fields with
                            | Some (`String msg) -> Some msg
                            | _ -> Some "report generation failed")
                        | _ -> None)
                    | _ -> None
                  in
                  (match report_error with
                  | Some e -> (false, json_error e)
                  | None ->
                      let proof_json =
                        if generate_proof then
                          match
                            Team_session_engine_eio.prove_session
                              ~config:ctx.config ~session_id ~proof_level
                              ~generate_report_if_missing:generate_report
                          with
                          | Ok json ->
                              `Assoc [ ("status", `String "ok"); ("result", json) ]
                          | Error e ->
                              `Assoc
                                [
                                  ("status", `String "error");
                                  ("message", `String e);
                                ]
                        else
                          `Null
                      in
                      let proof_error =
                        match proof_json with
                        | `Assoc fields -> (
                            match List.assoc_opt "status" fields with
                            | Some (`String "error") -> (
                                match List.assoc_opt "message" fields with
                                | Some (`String msg) -> Some msg
                                | _ -> Some "proof generation failed")
                            | _ -> None)
                        | _ -> None
                      in
                      match proof_error with
                      | Some e -> (false, json_error e)
                      | None ->
                          ( true,
                            json_ok
                              [
                                ( "result",
                                  `Assoc
                                    [
                                      ("session_id", `String session_id);
                                      ("terminal_status", `String terminal_status);
                                      ("stop", stop_json);
                                      ("status", status_json);
                                      ("report", report_json);
                                      ("proof", proof_json);
                                    ] );
                              ] )))

let handle_events ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () ->
          let event_types = get_string_list args "event_types" in
          let limit = get_int args "limit" 200 in
          let after_ts = get_float_opt args "after_ts" in
          (match
             Team_session_engine_eio.list_events ~config:ctx.config ~session_id
               ~event_types ~limit ~after_ts
           with
          | Ok json -> (true, json_ok [ ("result", json) ])
          | Error e -> (false, json_error e)))

let handle_prove ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () ->
          let generate_report_if_missing =
            get_bool args "generate_report_if_missing" true
          in
          let proof_level = parse_proof_level args in
          (match
             Team_session_engine_eio.prove_session ~config:ctx.config ~session_id
               ~proof_level
               ~generate_report_if_missing
           with
          | Ok json -> (true, json_ok [ ("result", json) ])
          | Error e -> (false, json_error e)))

let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_team_session_start" -> Some (handle_start ctx args)
  | "masc_team_session_step" -> Some (handle_step ctx args)
  | "masc_team_session_status" -> Some (handle_status ctx args)
  | "masc_team_session_finalize" -> Some (handle_finalize ctx args)
  | "masc_team_session_stop" -> Some (handle_stop ctx args)
  | "masc_team_session_report" -> Some (handle_report ctx args)
  | "masc_team_session_list" -> Some (handle_list ctx args)
  | "masc_team_session_compare" -> Some (handle_compare ctx args)
  | "masc_team_session_turn" -> Some (handle_turn ctx args)
  | "masc_team_session_events" -> Some (handle_events ctx args)
  | "masc_team_session_prove" -> Some (handle_prove ctx args)
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
                  ( "duration_minutes",
                    `Assoc
                      [
                        ("type", `String "integer");
                        ( "description",
                          `String
                            "Session duration in minutes (used when duration_seconds is omitted)" );
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
                              `String "local_first_conditional";
                              `String "strict_local_only";
                              `String "cloud_first";
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
                        ( "items",
                          `Assoc
                            [
                              ( "oneOf",
                                `List
                                  [
                                    `Assoc [ ("type", `String "string") ];
                                    `Assoc
                                      [
                                        ("type", `String "object");
                                        ( "properties",
                                          `Assoc
                                            [
                                              ("name", `Assoc [ ("type", `String "string") ]);
                                            ] );
                                      ];
                                  ] );
                            ] );
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
      name = "masc_team_session_step";
      description =
        "Execute one orchestrated team step: optionally spawn a worker, optionally record a supervisor turn, and optionally attach vote/run evidence.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ( "turn_kind",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "note";
                              `String "broadcast";
                              `String "portal";
                              `String "task";
                              `String "checkpoint";
                            ] );
                      ] );
                  ("actor", `Assoc [ ("type", `String "string") ]);
                  ("message", `Assoc [ ("type", `String "string") ]);
                  ("target_agent", `Assoc [ ("type", `String "string") ]);
                  ("task_title", `Assoc [ ("type", `String "string") ]);
                  ("task_description", `Assoc [ ("type", `String "string") ]);
                  ("task_priority", `Assoc [ ("type", `String "integer") ]);
                  ("spawn_agent", `Assoc [ ("type", `String "string") ]);
                  ("spawn_model", `Assoc [ ("type", `String "string") ]);
                  ("spawn_role", `Assoc [ ("type", `String "string") ]);
                  ("spawn_selection_note", `Assoc [ ("type", `String "string") ]);
                  ("spawn_prompt", `Assoc [ ("type", `String "string") ]);
                  ("spawn_timeout_seconds", `Assoc [ ("type", `String "integer") ]);
                  ("vote_topic", `Assoc [ ("type", `String "string") ]);
                  ( "vote_options",
                    `Assoc
                      [
                        ("type", `String "array");
                        ("items", `Assoc [ ("type", `String "string") ]);
                      ] );
                  ("vote_required_votes", `Assoc [ ("type", `String "integer") ]);
                  ("vote_choice", `Assoc [ ("type", `String "string") ]);
                  ("run_task_id", `Assoc [ ("type", `String "string") ]);
                  ("run_note", `Assoc [ ("type", `String "string") ]);
                  ("run_deliverable", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_team_session_finalize";
      description =
        "Stop session, wait for terminal status, then optionally generate report and proof in one command.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ("reason", `Assoc [ ("type", `String "string") ]);
                  ("wait_timeout_sec", `Assoc [ ("type", `String "integer") ]);
                  ("generate_report", `Assoc [ ("type", `String "boolean") ]);
                  ("generate_proof", `Assoc [ ("type", `String "boolean") ]);
                  ( "proof_level",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("enum", `List [ `String "standard"; `String "strong" ]);
                      ] );
                ] );
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
    {
      name = "masc_team_session_turn";
      description =
        "Record a team orchestration turn and optionally execute broadcast/portal/task/checkpoint action.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ( "turn_kind",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "note";
                              `String "broadcast";
                              `String "portal";
                              `String "task";
                              `String "checkpoint";
                            ] );
                      ] );
                  ("message", `Assoc [ ("type", `String "string") ]);
                  ("target_agent", `Assoc [ ("type", `String "string") ]);
                  ("task_title", `Assoc [ ("type", `String "string") ]);
                  ("task_description", `Assoc [ ("type", `String "string") ]);
                  ("task_priority", `Assoc [ ("type", `String "integer") ]);
                ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_team_session_events";
      description =
        "Read team session event timeline with optional event type and timestamp filters.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ( "event_types",
                    `Assoc
                      [
                        ("type", `String "array");
                        ("items", `Assoc [ ("type", `String "string") ]);
                      ] );
                  ("after_ts", `Assoc [ ("type", `String "number") ]);
                  ("limit", `Assoc [ ("type", `String "integer") ]);
                ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_team_session_prove";
      description =
        "Generate verifiable proof artifacts (proof.json/proof.md) for a team session based on timeline evidence.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ( "generate_report_if_missing",
                    `Assoc [ ("type", `String "boolean") ] );
                  ( "proof_level",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("enum", `List [ `String "standard"; `String "strong" ]);
                      ] );
                ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
  ]
