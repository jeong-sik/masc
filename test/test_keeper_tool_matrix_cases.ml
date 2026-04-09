module Generic = Test_mcp_tool_matrix_cases
module KET = Masc_mcp.Keeper_exec_tools
module KTO = Masc_mcp.Keeper_tools_oas
module Tool = Agent_sdk.Tool

type init_mode = Generic.init_mode =
  | Fresh
  | Init_only
  | Init_joined

type expectation = Generic.expectation =
  | Expect_success
  | Expect_success_or_guard of string list
  | Expect_guard of string list

type keeper_case = {
  init_mode : init_mode;
  prepare : fixture -> unit;
  arguments : fixture -> Types.tool_schema -> Yojson.Safe.t;
  expectation : expectation;
}

and fixture = {
  generic : Generic.fixture;
  config : Masc_mcp.Room.config;
  meta : Masc_mcp.Keeper_types.keeper_meta;
  ctx_snapshot : Masc_mcp.Keeper_types.working_context;
  tools : Agent_sdk.Tool.t list;
}

let string_starts_with = Generic.string_starts_with
let contains_any = Generic.contains_any
let cleanup_dir = Generic.cleanup_dir

let keeper_matrix_guard_fragments =
  [
    "tool_not_allowed";
    "tool_not_supported_in_keeper";
    "unknown_tool";
    "unregistered_masc_tool";
  ]

let dedupe_tool_schemas (schemas : Types.tool_schema list) =
  let seen = Hashtbl.create (max 16 (List.length schemas)) in
  List.filter
    (fun (schema : Types.tool_schema) ->
      if Hashtbl.mem seen schema.name then
        false
      else (
        Hashtbl.replace seen schema.name ();
        true))
    schemas

let github_guard_fragments =
  Generic.git_guard_fragments
  @ Generic.provider_guard_fragments
  @
  [
    "not logged into any github hosts";
    "authentication failed";
    "gh auth login";
    "gh_token";
    "gh: command not found";
    "could not resolve host";
  ]

let voice_guard_fragments =
  Generic.provider_guard_fragments
  @
  [
    "rec process failed";
    "no active audio session";
    "transcription";
    "microphone";
    "audio";
  ]

let init_keeper_bridge () =
  Masc_test_deps.init_keeper_tool_registry ();
  ignore (Masc_mcp.Mcp_server_eio.get_clock_opt ());
  (match KET.init_policy_config ~base_path:(Sys.getcwd ()) with
   | Ok () -> ()
   | Error err -> Printf.eprintf "[WARN] init_policy_config failed: %s\n" err);
  Masc_mcp.Keeper_exec_shared.tag_dispatch_fn := Masc_mcp.Keeper_tag_dispatch.dispatch;
  KET.inject_masc_schemas Masc_mcp.Config.raw_all_tool_schemas

let make_meta ?(name = "keeper-tool-matrix") () =
  match
    Masc_mcp.Keeper_types.meta_of_json
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String name);
          ("trace_id", `String "keeper-tool-matrix-trace");
          ("allowed_paths", `List [ `String "*" ]);
          ( "tool_access",
            Masc_mcp.Keeper_types.tool_access_to_json
              (Masc_mcp.Keeper_types.Preset
                 { preset = Masc_mcp.Keeper_types.Full; also_allow = [] } ) );
        ])
  with
  | Ok meta -> meta
  | Error err -> failwith ("make_meta failed: " ^ err)

let all_keeper_tool_schemas_raw () =
  init_keeper_bridge ();
  KET.keeper_allowed_model_tools (make_meta ())
  |> List.sort (fun (left : Types.tool_schema) right ->
         String.compare left.name right.name)

let all_keeper_tool_schemas () =
  all_keeper_tool_schemas_raw ()
  |> dedupe_tool_schemas

let all_keeper_tool_names =
  all_keeper_tool_schemas_raw ()
  |> List.map (fun (schema : Types.tool_schema) -> schema.name)

let make_fixture sw ~proc_mgr ~fs ~net ~mono_clock clock ~base_path init_mode =
  init_keeper_bridge ();
  let generic =
    Generic.make_fixture sw ~proc_mgr ~fs ~net ~mono_clock clock ~base_path init_mode
  in
  let config = Masc_mcp.Room.default_config base_path in
  let ctx =
    Masc_mcp.Keeper_exec_context.create ~system_prompt:"keeper tool matrix"
      ~max_tokens:4000
    |> fun ctx ->
    Masc_mcp.Keeper_exec_context.append ctx
      (Agent_sdk.Types.user_msg "tool matrix memory needle")
  in
  let ctx_snapshot = ctx in
  let meta = make_meta () in
  let tools = KTO.make_tools ~config ~meta ~ctx_snapshot () in
  (match init_mode with
   | Init_joined ->
       ignore
         (Masc_mcp.Room.join config ~agent_name:("keeper-" ^ meta.name)
            ~capabilities:[] ())
   | Fresh | Init_only -> ());
  { generic; config; meta; ctx_snapshot; tools }

let keeper_agent_name fixture = "keeper-" ^ fixture.meta.name

let find_tool fixture name =
  List.find_opt
    (fun (tool : Agent_sdk.Tool.t) -> String.equal tool.schema.name name)
    fixture.tools

let ensure_sample_file fixture =
  let relative = "keeper-tool-matrix.txt" in
  let absolute = Filename.concat fixture.generic.base_path relative in
  Generic.write_text_file absolute "needle\nsecond line\n";
  relative

let ensure_keeper_claim fixture =
  ignore (Generic.ensure_task fixture.generic);
  ignore
    (Masc_mcp.Room.claim_next fixture.config
       ~agent_name:(keeper_agent_name fixture))

let ensure_voice_session fixture =
  let mgr = Masc_mcp.Keeper_voice_local.get_session_manager () in
  ignore
    (Masc_mcp.Voice_session_manager.start_session mgr ~agent_id:fixture.meta.name
       ~voice:"tool-matrix" ())

let prepare_keeper_name fixture name =
  if
    List.mem name
      [ "keeper_board_get"; "keeper_board_comment"; "keeper_board_vote";
        "keeper_board_search" ]
  then
    ignore (Generic.ensure_board_post fixture.generic);
  if
    List.mem name
      [ "keeper_library_search"; "keeper_library_read" ]
  then
    ignore (Generic.ensure_library_topic fixture.generic);
  if
    List.mem name
      [ "keeper_task_claim"; "keeper_tasks_list"; "keeper_tasks_audit";
        "keeper_task_force_release"; "keeper_task_force_done";
        "keeper_task_done" ]
  then
    ignore (Generic.ensure_task fixture.generic);
  if
    List.mem name
      [ "keeper_task_force_release"; "keeper_task_force_done";
        "keeper_task_done" ]
  then
    ensure_keeper_claim fixture;
  if name = "keeper_voice_session_end" then ensure_voice_session fixture;
  (* keeper_memory_search: needle "tool matrix memory needle" is already
     in ctx_snapshot from fixture creation (line ~128). No mutation needed. *)
  ignore (name = "keeper_memory_search")

let keeper_arguments fixture (schema : Types.tool_schema) =
  let name = schema.name in
  match name with
  | "keeper_time_now"
  | "keeper_context_status"
  | "keeper_tools_list"
  | "keeper_tasks_audit"
  | "keeper_task_claim"
  | "keeper_voice_agent"
  | "keeper_voice_sessions"
  | "keeper_voice_session_end" ->
      `Assoc []
  | "keeper_memory_search" ->
      `Assoc [ ("query", `String "memory needle"); ("limit", `Int 2) ]
  | "keeper_board_post" ->
      `Assoc
        [
          ("title", `String "Keeper Tool Matrix");
          ("content", `String "tool-matrix-post");
          ("visibility", `String "internal");
        ]
  | "keeper_board_get" ->
      `Assoc [ ("post_id", `String (Generic.ensure_board_post fixture.generic)) ]
  | "keeper_board_list" -> `Assoc [ ("limit", `Int 5) ]
  | "keeper_board_comment" ->
      `Assoc
        [
          ("post_id", `String (Generic.ensure_board_post fixture.generic));
          ("content", `String "tool-matrix-comment");
        ]
  | "keeper_board_vote" ->
      `Assoc
        [
          ("post_id", `String (Generic.ensure_board_post fixture.generic));
          ("direction", `String "up");
        ]
  | "keeper_board_stats" -> `Assoc []
  | "keeper_board_search" ->
      `Assoc [ ("query", `String "tool-matrix"); ("limit", `Int 5) ]
  | "keeper_fs_read" ->
      `Assoc [ ("path", `String (ensure_sample_file fixture)) ]
  | "keeper_fs_edit" ->
      `Assoc
        [
          ("path", `String "keeper-matrix-write.txt");
          ("content", `String "matrix write\n");
          ("mode", `String "overwrite");
        ]
  | "keeper_shell_readonly" -> `Assoc [ ("op", `String "git_status") ]
  | "keeper_bash" ->
      `Assoc [ ("cmd", `String "pwd"); ("timeout_sec", `Float 5.0) ]
  | "keeper_github" ->
      `Assoc [ ("cmd", `String "status"); ("timeout_sec", `Float 5.0) ]
  | "keeper_voice_speak" ->
      `Assoc [ ("message", `String "tool matrix hello") ]
  | "keeper_voice_listen" ->
      `Assoc [ ("timeout_seconds", `Float 1.0) ]
  | "keeper_voice_session_start" ->
      `Assoc [ ("session_name", `String "tool-matrix") ]
  | "keeper_library_search" ->
      `Assoc [ ("query", `String "tool matrix") ]
  | "keeper_library_read" ->
      `Assoc [ ("topic", `String (Generic.ensure_library_topic fixture.generic)) ]
  | "keeper_tasks_list" -> `Assoc [ ("include_done", `Bool true) ]
  | "keeper_task_force_release" ->
      `Assoc
        [
          ("task_id", `String (Generic.ensure_task fixture.generic));
          ("reason", `String "tool matrix release");
        ]
  | "keeper_task_force_done" ->
      `Assoc
        [
          ("task_id", `String (Generic.ensure_task fixture.generic));
          ("notes", `String "tool matrix done");
        ]
  | "keeper_broadcast" ->
      `Assoc [ ("message", `String "tool matrix broadcast") ]
  | "keeper_task_done" ->
      `Assoc
        [
          ("task_id", `String (Generic.ensure_task fixture.generic));
          ("result", `String "tool matrix result");
        ]
  | other -> failwith ("missing keeper arguments contract for " ^ other)

let keeper_expectation_for_name name =
  match name with
  | "keeper_github" -> Expect_success_or_guard github_guard_fragments
  | "keeper_voice_listen"
  | "keeper_voice_agent" ->
      Expect_success_or_guard voice_guard_fragments
  | _ -> Expect_success

let extra_guard_fragments_for_name = function
  | "masc_auth_refresh" ->
      [ "agent_name must match the authenticated agent";
        "no credential found" ]
  | "masc_auth_revoke" -> [ "no credential found" ]
  | "masc_autoresearch_cycle"
  | "masc_autoresearch_inject"
  | "masc_autoresearch_status"
  | "masc_autoresearch_stop" ->
      [ "no autoresearch loop running" ]
  | "masc_autoresearch_swarm_start" ->
      [ "requires local team-session runtime context" ]
  | "masc_board_migrate" -> [ "requires postgresql backend" ]
  | "masc_get_metrics" -> [ "no metrics found" ]
  | "masc_library_promote" -> [ "no candidate matching" ]
  | "masc_portal_send" -> [ "no portal open" ]
  | "masc_worktree_remove" -> [ "worktree not found" ]
  | _ -> []

let merge_expectation base extras =
  match base with
  | Expect_success when extras <> [] -> Expect_success_or_guard extras
  | Expect_success -> Expect_success
  | Expect_guard fragments -> Expect_guard (fragments @ extras)
  | Expect_success_or_guard fragments ->
      Expect_success_or_guard (fragments @ extras)

let case_for_name name =
  if string_starts_with ~prefix:"masc_" name then
    let generic_case = Generic.case_for_name name in
    {
      init_mode = generic_case.init_mode;
      prepare = (fun fixture -> Generic.prepare_for_name fixture.generic name);
      arguments =
        (fun fixture schema -> Generic.tool_arguments fixture.generic schema);
      expectation =
        merge_expectation generic_case.expectation
          (extra_guard_fragments_for_name name);
    }
  else if string_starts_with ~prefix:"keeper_" name then
    {
      init_mode = Init_joined;
      prepare = (fun fixture -> prepare_keeper_name fixture name);
      arguments = keeper_arguments;
      expectation = keeper_expectation_for_name name;
    }
  else
    failwith ("missing keeper tool contract for " ^ name)

let fatal_fragments =
  Generic.fatal_fragments @ keeper_matrix_guard_fragments

let evaluate_expectation ~name expectation = function
  | Ok _ ->
      (match expectation with
       | Expect_success -> Ok ()
       | Expect_success_or_guard _ -> Ok ()
       | Expect_guard fragments ->
           Error
             (Printf.sprintf "%s expected guard %s but succeeded" name
                (String.concat ", " fragments)))
  | Error { Agent_sdk.Types.message; _ } ->
      if contains_any message fatal_fragments then
        Error
          (Printf.sprintf "%s hit fatal keeper-tool failure: %s" name message)
      else
        match expectation with
        | Expect_success ->
            Error
              (Printf.sprintf "%s expected success but got error: %s" name
                 message)
        | Expect_guard fragments ->
            if contains_any message fragments then
              Ok ()
            else
              Error
                (Printf.sprintf "%s expected guard %s but got: %s" name
                   (String.concat ", " fragments) message)
        | Expect_success_or_guard fragments ->
            if contains_any message fragments then
              Ok ()
            else
              Error
                (Printf.sprintf
                   "%s expected success or guard %s but got: %s"
                   name
                   (String.concat ", " fragments)
                   message)

let run_case sw ~proc_mgr ~fs ~net ~mono_clock clock
    (schema : Types.tool_schema) =
  let saved_home = Sys.getenv_opt "HOME" in
  let saved_env =
    [
      ("MASC_BASE_PATH", Sys.getenv_opt "MASC_BASE_PATH");
      ("MASC_STORAGE_TYPE", Sys.getenv_opt "MASC_STORAGE_TYPE");
      ("MASC_POSTGRES_URL", Sys.getenv_opt "MASC_POSTGRES_URL");
      ("DATABASE_URL", Sys.getenv_opt "DATABASE_URL");
      ("SUPABASE_DB_URL", Sys.getenv_opt "SUPABASE_DB_URL");
      ("SB_PG_URL", Sys.getenv_opt "SB_PG_URL");
    ]
  in
  Unix.putenv "MASC_STORAGE_TYPE" "filesystem";
  Unix.putenv "MASC_POSTGRES_URL" "";
  Unix.putenv "DATABASE_URL" "";
  Unix.putenv "SUPABASE_DB_URL" "";
  Unix.putenv "SB_PG_URL" "";
  let base_path = Generic.temp_dir "keeper-tool-matrix-" in
  Unix.putenv "MASC_BASE_PATH" base_path;
  let result =
    Fun.protect
      ~finally:(fun () ->
        List.iter
          (fun (name, value) ->
            match value with
            | Some raw -> Unix.putenv name raw
            | None -> Unix.putenv name "")
          saved_env;
        match saved_home with
        | Some home -> Unix.putenv "HOME" home
        | None -> Unix.putenv "HOME" "")
      (fun () ->
        Unix.putenv "HOME" base_path;
        try
          let case = case_for_name schema.Types.name in
          let fixture =
            make_fixture sw ~proc_mgr ~fs ~net ~mono_clock clock ~base_path
              case.init_mode
          in
          case.prepare fixture;
          let args = case.arguments fixture schema in
          match find_tool fixture schema.Types.name with
          | None ->
              Error
                (Printf.sprintf "missing keeper Tool.t for %s" schema.Types.name)
          | Some tool ->
              let outcome = Tool.execute tool args in
              if String.equal schema.Types.name "masc_heartbeat_start" then
                Heartbeat.list ()
                |> List.iter (fun (hb : Heartbeat.t) ->
                       ignore (Heartbeat.stop hb.id));
              evaluate_expectation ~name:schema.Types.name case.expectation
                outcome
        with exn ->
          Error
            (Printf.sprintf "%s raised during keeper case: %s"
               schema.Types.name (Printexc.to_string exn)))
  in
  (base_path, result)
