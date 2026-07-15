module Types = Masc_domain

module Generic = Test_mcp_tool_matrix_cases
module KET = Masc.Keeper_tool_dispatch_runtime
module KTO = Masc.Keeper_tools_oas_bundle
module Tool = Agent_sdk.Tool

external unsetenv : string -> unit = "masc_test_unsetenv"

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
  arguments : fixture -> Masc_domain.tool_schema -> Yojson.Safe.t;
  expectation : expectation;
}

and fixture = {
  generic : Generic.fixture;
  config : Masc.Workspace.config;
  meta : Masc.Keeper_meta_contract.keeper_meta;
  ctx_snapshot : Keeper_types.working_context;
  tools : Agent_sdk.Tool.t list;
}

let string_starts_with = Generic.string_starts_with
let contains_any = Generic.contains_any
let cleanup_dir = Generic.cleanup_dir

let restore_env name = function
  | Some raw -> Unix.putenv name raw
  | None -> unsetenv name
;;

let keeper_matrix_guard_fragments =
  [
    "tool_not_allowed";
    "tool_not_supported_in_keeper";
    "unknown_tool";
    "unregistered_masc_tool";
  ]

let dedupe_tool_schemas (schemas : Masc_domain.tool_schema list) =
  let seen = Hashtbl.create (max 16 (List.length schemas)) in
  List.filter
    (fun (schema : Masc_domain.tool_schema) ->
      if Hashtbl.mem seen schema.name then
        false
      else (
        Hashtbl.replace seen schema.name ();
        true))
    schemas

let voice_guard_fragments =
  Generic.provider_guard_fragments
  @
  [
    "rec process failed";
    "no active audio session";
    "transcription";
    "microphone";
    "audio";
    "rec exit";
    "no configured tts endpoint";
    "tts endpoint";
  ]

let test_runtime_toml =
  {|
[runtime]
default = "test_provider.test_model"

[providers.test_provider]
display-name = "Test Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[test_provider.test_model]
is-default = true
max-concurrent = 1
|}

let init_keeper_bridge =
  let initialized = ref false in
  fun () ->
    if not !initialized then (
      initialized := true;
      Masc_test_deps.init_keeper_tool_registry ();
      ignore (Masc.Mcp_server_eio.get_clock_opt ());
      (* Use find_project_root — the test cwd is _build/default/test/ which
         does not contain dune-project, so Sys.getcwd fails the
         direct shortcut and falls into the exe-relative walk that picks up
         the partial _build/default/config/runtime.json. *)
      let base_path = Masc_test_deps.find_project_root () in
      let runtime_config_path = Filename.concat base_path "config/runtime.toml" in
      let config_path =
        if Sys.file_exists runtime_config_path then
          runtime_config_path
        else (
          let temp_path = Filename.temp_file "keeper_matrix_runtime_" ".toml" in
          let oc = open_out temp_path in
          output_string oc test_runtime_toml;
          close_out oc;
          temp_path)
      in
      (match Runtime.init_default ~config_path with
       | Ok () -> ()
       | Error err -> Printf.eprintf "[WARN] Runtime.init_default failed: %s\n" err);
      Masc.Keeper_tool_shared_runtime.tag_dispatch_fn := Masc.Keeper_tag_dispatch.dispatch;
      KET.inject_masc_schemas Masc.Config.raw_all_tool_schemas)

let keeper_matrix_owner = "keeper-tool-matrix"

let make_meta ?(name = keeper_matrix_owner) () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String name);
          ("trace_id", `String "keeper-tool-matrix-trace");
          ("allowed_paths", `List [ `String "*" ]);
        ])
  with
  | Ok meta -> meta
  | Error err -> failwith ("make_meta failed: " ^ err)

let all_keeper_tool_schemas_raw () =
  init_keeper_bridge ();
  KET.keeper_model_tool_schemas ()
  |> List.sort (fun (left : Masc_domain.tool_schema) right ->
         String.compare left.name right.name)

let all_keeper_tool_schemas () =
  all_keeper_tool_schemas_raw ()
  |> dedupe_tool_schemas

let all_keeper_tool_names =
  all_keeper_tool_schemas_raw ()
  |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)

let make_fixture
      sw
      ~proc_mgr
      ~fs
      ~net
      ~mono_clock
      clock
      ~base_path
      ~meta
      ~publication_recovery
      init_mode
  =
  init_keeper_bridge ();
  let generic =
    Generic.make_fixture sw ~proc_mgr ~fs ~net ~mono_clock clock ~base_path init_mode
  in
  let config = Masc.Workspace.default_config base_path in
  let ctx =
    Masc.Keeper_context_runtime.create ~eio:false
      ~system_prompt:"keeper tool matrix"
      ~max_tokens:4000
    |> fun ctx ->
    Masc.Keeper_context_runtime.append ctx
      (Agent_sdk.Types.user_msg "tool matrix memory needle")
  in
  let ctx_snapshot = ctx in
  Masc.Keeper_registry.clear ();
  ignore (Masc.Keeper_registry.register ~base_path meta.name meta);
  ignore (Masc.Keeper_registry.register ~base_path "tool-matrix" meta);
  let tools =
    KTO.make_tools
      ~config
      ~meta
      ~publication_recovery
      ~ctx_snapshot
      ()
  in
  (match init_mode with
   | Init_joined ->
       (* Bind under both the raw meta name (used by masc_* tools called
          through the keeper) and the prefixed keeper alias. Some keeper
          tools resolve the agent through the prefixed alias while
          dispatched masc tools use the raw meta identity. *)
       ignore
         (Masc.Workspace.bind_session config ~agent_name:meta.name
            ~capabilities:[] ());
       ignore
         (Masc.Workspace.bind_session config ~agent_name:("keeper-" ^ meta.name)
            ~capabilities:[] ())
   | Fresh | Init_only -> ());
  { generic; config; meta; ctx_snapshot; tools }

let find_tool fixture name =
  let by_name tool_name =
    List.find_opt
      (fun (tool : Agent_sdk.Tool.t) -> String.equal tool.schema.name tool_name)
      fixture.tools
  in
  match by_name name with
  | Some _ as found -> found
  | None ->
    (match Masc.Keeper_tool_alias.public_name_for_internal name with
     | Some public -> by_name public
     | None -> None)

let ensure_sample_file fixture =
  let relative = "keeper-tool-matrix.txt" in
  let absolute =
    Filename.concat
      (Masc.Keeper_sandbox.host_root_abs_of_meta ~config:fixture.config fixture.meta)
      relative
  in
  Generic.mkdir_p (Filename.dirname absolute);
  Generic.write_text_file absolute "needle\nsecond line\n";
  relative

let ensure_keeper_claim fixture =
  ignore (Generic.ensure_task fixture.generic);
  ignore
    (Masc.Workspace.claim_next fixture.config
       ~agent_name:fixture.meta.agent_name)

let ensure_voice_session fixture =
  let mgr = Masc.Keeper_voice_local.get_session_manager () in
  ignore
    (Masc.Voice_session_manager.start_session mgr ~agent_id:fixture.meta.name
       ~voice:"tool-matrix" ())

let ensure_board_comment fixture =
  let body =
    Generic.execute_tool_ok fixture.generic ~name:"masc_board_comment"
      ~arguments:
        (`Assoc
          [
            ("post_id", `String (Generic.ensure_board_post fixture.generic));
            ("author", `String fixture.meta.name);
            ("content", `String "tool-matrix-comment");
          ])
  in
  match
    Generic.extract_id body ~fields:[ "id"; "comment_id" ]
      ~prefixes:[ "comment-" ]
  with
  | Some value -> value
  | None -> failwith ("failed to parse comment id from: " ^ body)

let sub_board_slug fixture =
  "tool-matrix-" ^ Filename.basename fixture.generic.base_path

let ensure_sub_board fixture =
  let slug = sub_board_slug fixture in
  ignore
    (Generic.execute_tool_ok fixture.generic ~name:"masc_board_sub_board_create"
       ~arguments:
         (`Assoc
           [
             ("slug", `String slug);
             ("name", `String "Tool Matrix SubBoard");
             ("description", `String "Sub-board fixture for keeper matrix");
             ("access", `String "open");
           ]));
  slug

let prepare_keeper_name fixture name =
  if
    List.mem name
      [
        "keeper_board_post_get";
        "keeper_board_comment";
        "keeper_board_vote";
        "keeper_board_comment_vote";
        "keeper_board_search";
      ]
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
        "keeper_task_done" ]
  then
    ignore (Generic.ensure_task fixture.generic);
  if
    List.mem name
      [ "keeper_task_done" ]
  then
    ensure_keeper_claim fixture;
  if name = "keeper_voice_session_end" then ensure_voice_session fixture;
  if name = "keeper_ide_annotate" then ignore (ensure_sample_file fixture);
  (* keeper_memory_search: needle "tool matrix memory needle" is already
     in ctx_snapshot from fixture creation (line ~128). No mutation needed. *)
  ignore (name = "keeper_memory_search")

let keeper_arguments fixture (schema : Masc_domain.tool_schema) =
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
  | "keeper_memory_write" ->
      `Assoc [ ("kind", `String "decision"); ("content", `String "tool matrix memory write content") ]
  | "analyze_image" ->
      `Assoc [ ("artifact", `String "tool-matrix-missing-query") ]
  | "keeper_ide_annotate" ->
      `Assoc
        [
          ("file_path", `String (ensure_sample_file fixture));
          ("line_start", `Int 1);
          ("content", `String "tool matrix ide annotation");
        ]
  | "keeper_board_post" ->
      `Assoc
        [
          ("title", `String "Keeper Tool Matrix");
          ("content", `String "tool-matrix-post");
          ("visibility", `String "internal");
        ]
  | "keeper_board_post_get" ->
      `Assoc [ ("post_id", `String (Generic.ensure_board_post fixture.generic)) ]
  | "keeper_board_list" -> `Assoc [ ("limit", `Int 5) ]
  | "keeper_board_curation_read" -> `Assoc []
  | "keeper_board_curation_submit" ->
      `Assoc [ ("rationale", `String "tool matrix curation") ]
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
  | "keeper_board_comment_vote" ->
      `Assoc
        [
          ("comment_id", `String (ensure_board_comment fixture));
          ("direction", `String "up");
        ]
  | "keeper_board_stats" -> `Assoc []
  | "keeper_board_search" ->
      `Assoc [ ("query", `String "tool-matrix"); ("limit", `Int 5) ]
  | "keeper_board_sub_board_create" ->
      `Assoc
        [
          ("slug", `String (sub_board_slug fixture));
          ("name", `String "Tool Matrix SubBoard");
          ("description", `String "Sub-board fixture for keeper matrix");
          ("access", `String "open");
        ]
  | "keeper_board_sub_board_list" -> `Assoc []
  | "keeper_board_sub_board_get" ->
      `Assoc [ ("sub_board_id", `String (ensure_sub_board fixture)) ]
  | "keeper_board_sub_board_update" ->
      `Assoc
        [
          ("sub_board_id", `String (ensure_sub_board fixture));
          ("name", `String "Tool Matrix SubBoard Updated");
        ]
  | "keeper_board_sub_board_delete" ->
      `Assoc [ ("sub_board_id", `String (ensure_sub_board fixture)) ]
  | "tool_read_file" ->
      `Assoc [ ("file_path", `String (ensure_sample_file fixture)) ]
  | "tool_edit_file" ->
      `Assoc
        [
          ("file_path", `String (ensure_sample_file fixture));
          ("old_string", `String "needle");
          ("new_string", `String "edited needle");
        ]
  | "tool_search_files" ->
      `Assoc
        [
          ("pattern", `String "needle");
          ("path", `String (ensure_sample_file fixture));
        ]
  | "tool_write_file" ->
      `Assoc
        [
          ("file_path", `String "keeper-matrix-write.txt");
          ("content", `String "matrix write\n");
          ("mode", `String "overwrite");
        ]
  | "tool_execute" ->
      `Assoc
        [ ("argv", `List [ `String "pwd" ]); ("timeout_sec", `Float 5.0) ]
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
  | "keeper_surface_read" -> `Assoc [ ("surface", `String "dashboard") ]
  | "keeper_surface_post" ->
      `Assoc
        [ ("surface", `String "dashboard");
          ("content", `String "tool matrix surface post") ]
  | "keeper_person_note_set" ->
      `Assoc
        [ ("speaker_id", `String "98791450001");
          ("note", `String "tool matrix person note") ]
  | "keeper_tasks_list" -> `Assoc [ ("include_done", `Bool true) ]
  | "keeper_broadcast" ->
      `Assoc [ ("message", `String "tool matrix broadcast") ]
  | "keeper_task_done" ->
      (* The completion text intentionally contains the "follow-up"
         excuse pattern so the anti-rationalization gate fast-rejects
         on Gate 2 (excuse pattern) without invoking the cross_verifier
         LLM runtime. The matrix runs in environments where the
         evaluator runtime is unreachable, and the LLM path's 180s
         timeout would always exceed the 25s per-case budget. The
         expectation table accepts the structured rejection. *)
      `Assoc
        [
          ("task_id", `String (Generic.ensure_task fixture.generic));
          ( "result",
            `String
              "Validated the keeper tool matrix case as a follow-up smoke check, confirmed the task fixture was claimed, and recorded the successful completion path." );
          ("evidence_refs", `List [ `String "trace:tool-matrix-task-done" ]);
        ]
  | "keeper_task_create" ->
      `Assoc
        [
          ("title", `String "tool matrix task");
          ("priority", `Int 3);
          ("description", `String "tool matrix task body");
        ]
  | "keeper_tool_search" ->
      `Assoc [ ("query", `String "tool matrix") ]
  | other -> failwith ("missing keeper arguments contract for " ^ other)

let keeper_expectation_for_name name =
  match name with
  | "keeper_voice_listen"
  | "keeper_voice_speak"
  | "keeper_voice_agent" ->
      Expect_success_or_guard voice_guard_fragments
  | "keeper_task_done" ->
      Expect_success_or_guard
        [
          "Completion rejected by anti-rationalization gate";
          "review format unrecognized";
          "Revise your completion notes";
        ]
  | "analyze_image" ->
      Expect_guard
        [
          "invalid_args";
          "requires string fields: artifact, query";
          "policy_rejection";
        ]
  | "keeper_ide_annotate" ->
      Expect_success_or_guard [ "annotation sink is not installed" ]
  | "tool_read_file" ->
      (* Playground resolves paths under .masc/playground/<agent>/ but
         the sample file is written at base_path. File-not-found in
         tests without a playground file is an acceptable outcome. *)
      Expect_success_or_guard
        [ "file not found"; "keeper not found in registry"; "path_outside_sandbox" ]
  | "tool_edit_file" | "tool_search_files" | "tool_write_file" ->
      Expect_success_or_guard
        [ "keeper not found in registry"; "tool call failed"; "path_outside_sandbox" ]
  | _ -> Expect_success

let extra_guard_fragments_for_name = function
  | "masc_auth_refresh" ->
      [ "agent_name must match the authenticated agent";
        "no credential found" ]
  | "masc_auth_revoke" -> [ "no credential found" ]
  | "masc_board_migrate" -> [ "requires postgresql backend" ]
  | "masc_dashboard" -> [ "Dashboard handler not registered" ]
  | "masc_get_metrics" -> [ "no metrics found" ]
  | "masc_fusion" ->
      [
        "fusion requires the server root switch + net (unavailable)";
        "\"reason\":\"disabled\"";
      ]
  | "masc_library_promote" -> [ "no candidate matching" ]
  | "masc_keeper_msg" ->
      [
        "keeper management tool";
        "use MCP client";
        "requires Eio context";
        "keeper not found";
      ]
  | "masc_keeper_sandbox_start" | "masc_keeper_sandbox_stop" ->
      [
        "keeper sandbox docker image is not configured";
        "docker_container_start_failed";
        "no such container";
      ]
  | "masc_keeper_list" | "masc_keeper_msg_result"
  | "masc_keeper_msg_cancel" | "masc_keeper_msg_queue" | "masc_keeper_status" ->
      [ "keeper management tool"; "use MCP client" ]
  | "masc_keeper_up" -> [ "server_initializing" ]
  | "tool_execute" -> [ "worktree not found" ]
  | _ -> []

let merge_expectation base extras =
  match base with
  | Expect_success when extras <> [] -> Expect_success_or_guard extras
  | Expect_success -> Expect_success
  | Expect_guard fragments -> Expect_guard (fragments @ extras)
  | Expect_success_or_guard fragments ->
      Expect_success_or_guard (fragments @ extras)

let case_for_name name =
  let runtime_name =
    match Masc.Keeper_tool_descriptor_resolution.descriptor_for_tool_name name with
    | Some (descriptor : Masc.Keeper_tool_descriptor.t) -> descriptor.internal_name
    | None -> name
  in
  if string_starts_with ~prefix:"masc_" runtime_name then
    let generic_case_opt =
      try Some (Generic.case_for_name runtime_name) with Failure _ -> None
    in
    (match generic_case_opt with
     | Some generic_case ->
       {
         init_mode = generic_case.init_mode;
         prepare = (fun fixture -> Generic.prepare_for_name fixture.generic runtime_name);
         arguments =
           (fun fixture schema ->
             Generic.tool_arguments
               fixture.generic
               { schema with name = runtime_name });
         expectation =
           merge_expectation generic_case.expectation
             (extra_guard_fragments_for_name runtime_name);
       }
     | None ->
       {
         init_mode = Init_only;
         prepare = (fun _fixture -> ());
         arguments =
           (fun fixture schema ->
             Generic.tool_arguments
               fixture.generic
               { schema with name = runtime_name });
         expectation =
           Expect_success_or_guard
             (Generic.guard_fragments_for_name runtime_name
              @ extra_guard_fragments_for_name runtime_name);
       })
  else if
    string_starts_with ~prefix:"keeper_" runtime_name
    || string_starts_with ~prefix:"tool_" runtime_name
    || String.equal runtime_name "analyze_image"
  then
    {
      init_mode = Init_joined;
      prepare = (fun fixture -> prepare_keeper_name fixture runtime_name);
      arguments =
        (fun fixture schema ->
          keeper_arguments fixture { schema with name = runtime_name });
      expectation = keeper_expectation_for_name runtime_name;
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
    (schema : Masc_domain.tool_schema) =
  let saved_home = Sys.getenv_opt "HOME" in
	  let saved_env =
	    [
	      ("MASC_BASE_PATH", Sys.getenv_opt "MASC_BASE_PATH");
	    ]
	  in
	  let base_path = Generic.temp_dir "keeper-tool-matrix-" in
  Unix.putenv "MASC_BASE_PATH" base_path;
  let result =
    Fun.protect
      ~finally:(fun () ->
        List.iter
          (fun (name, value) -> restore_env name value)
          saved_env;
        restore_env "HOME" saved_home)
      (fun () ->
        Unix.putenv "HOME" base_path;
        try
          let case = case_for_name schema.Masc_domain.name in
          let meta = make_meta () in
          Masc_test_deps.with_publication_recovery_registry
            ~sw
            ~fs
            ~registry_root:base_path
          @@ fun publication_recovery_registry ->
          let publication_recovery =
            Masc.Keeper_publication_recovery_availability.
              { provider =
                  Masc_test_deps.publication_recovery_provider
                    publication_recovery_registry
              ; keeper_name = meta.name
              }
          in
          let fixture =
            make_fixture
              sw
              ~proc_mgr
              ~fs
              ~net
              ~mono_clock
              clock
              ~base_path
              ~meta
              ~publication_recovery
              case.init_mode
          in
          case.prepare fixture;
          let args = case.arguments fixture schema in
          match find_tool fixture schema.Masc_domain.name with
          | None ->
            Error
              (Printf.sprintf
                 "missing keeper Tool.t for %s"
                 schema.Masc_domain.name)
          | Some tool ->
            let outcome = Tool.execute tool args in
            if String.equal schema.Masc_domain.name "masc_heartbeat_start"
            then
              Heartbeat.list ()
              |> List.iter (fun (hb : Heartbeat.t) ->
                   ignore (Heartbeat.stop hb.id));
            evaluate_expectation
              ~name:schema.Masc_domain.name
              case.expectation
              outcome
        with exn ->
          Error
            (Printf.sprintf "%s raised during keeper case: %s"
               schema.Masc_domain.name (Printexc.to_string exn)))
  in
  (base_path, result)
