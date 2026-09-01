module Types = Masc_domain

module Generic = Test_mcp_tool_matrix_cases
module KET = Masc.Keeper_tool_dispatch_runtime
module KTO = Masc.Keeper_tools_agent_core_bundle
module Tool = Agent_core.Tool

external unsetenv : string -> unit = "masc_test_unsetenv"

type init_mode = Generic.init_mode =
  | Fresh
  | Init_only
  | Init_joined

type expectation = Generic.expectation =
  | Expect_success
  | Expect_success_or_refusal
  | Expect_refusal
  | Expect_refusal_saying of string

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
  tools : Agent_core.Tool.t list;
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
      Masc_test_deps.init_unified_tool_registry ();
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
      Masc.Keeper_tool_shared_runtime.tag_dispatch_fn := Masc.Keeper_tag_dispatch.dispatch)

let keeper_matrix_owner = "keeper-tool-matrix"

let make_meta ?(name = keeper_matrix_owner) () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("trace_id", `String "keeper-tool-matrix-trace");
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
      ~(meta : Masc.Keeper_meta_contract.keeper_meta)
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
    |> fun ctx ->
    Masc.Keeper_context_runtime.append ctx
      (Agent_core.Types.user_msg "tool matrix memory needle")
  in
  let ctx_snapshot = ctx in
  Masc.Keeper_registry.For_testing.clear ();
  ignore (Masc.Keeper_registry.For_testing.register ~base_path meta.name meta);
  ignore (Masc.Keeper_registry.For_testing.register ~base_path "tool-matrix" meta);
  let tools =
    KTO.For_testing.make_tools
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
      (fun (tool : Agent_core.Tool.t) -> String.equal tool.schema.name tool_name)
      fixture.tools
  in
  match by_name name with
  | Some _ as found -> found
  | None ->
    (match Masc.Keeper_tool_descriptor_resolution.public_name_for_internal name with
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
    (Masc.Workspace.claim_next_r fixture.config
       ~agent_name:fixture.meta.name ())

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
        "masc_board_post_get";
        "masc_board_comment";
        "masc_board_vote";
        "masc_board_comment_vote";
        "masc_board_search";
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
  | "keeper_capability_search" ->
      `Assoc [ "query", `String "keeper_time_now" ]
  | "keeper_memory_search" ->
      `Assoc [ ("query", `String "memory needle"); ("limit", `Int 2) ]
  | "keeper_memory_retract" ->
      `Assoc
        [ "memory_id", `String ("sha256:" ^ String.make 64 '0')
        ; "reason", `String "tool matrix missing-fact refusal"
        ]
  | "keeper_memory_write" ->
      `Assoc [ ("content", `String "tool matrix memory write content") ]
  | "keeper_analyze_image" ->
      `Assoc [ ("artifact", `String "tool-matrix-missing-query") ]
  | "keeper_ide_annotate" ->
      (* RFC-0378 §5.3: the anchor is the co-view vocabulary — a codebase
         slug plus a repo-root-relative path, handed back verbatim. *)
      `Assoc
        [
          ("codebase", `String "github.com_owner_repo");
          ("file_path", `String "lib/sample.ml");
          ("line_start", `Int 1);
          ("content", `String "tool matrix ide annotation");
        ]
  | "masc_board_post" ->
      `Assoc
        [
          ("title", `String "Keeper Tool Matrix");
          ("content", `String "tool-matrix-post");
          ("visibility", `String "internal");
        ]
  | "masc_board_post_get" ->
      `Assoc [ ("post_id", `String (Generic.ensure_board_post fixture.generic)) ]
  | "masc_board_list" -> `Assoc [ ("limit", `Int 5) ]
  | "masc_board_curation_read" -> `Assoc []
  | "masc_board_curation_submit" ->
      `Assoc [ ("rationale", `String "tool matrix curation") ]
  | "masc_board_comment" ->
      `Assoc
        [
          ("post_id", `String (Generic.ensure_board_post fixture.generic));
          ("content", `String "tool-matrix-comment");
        ]
  | "masc_board_vote" ->
      `Assoc
        [
          ("post_id", `String (Generic.ensure_board_post fixture.generic));
          ("direction", `String "up");
        ]
  | "masc_board_comment_vote" ->
      `Assoc
        [
          ("comment_id", `String (ensure_board_comment fixture));
          ("direction", `String "up");
        ]
  | "masc_board_stats" -> `Assoc []
  | "masc_board_search" ->
      `Assoc [ ("query", `String "tool-matrix"); ("limit", `Int 5) ]
  | "masc_board_sub_board_create" ->
      `Assoc
        [
          ("slug", `String (sub_board_slug fixture));
          ("name", `String "Tool Matrix SubBoard");
          ("description", `String "Sub-board fixture for keeper matrix");
          ("access", `String "open");
        ]
  | "masc_board_sub_board_list" -> `Assoc []
  | "masc_board_sub_board_get" ->
      `Assoc [ ("sub_board_id", `String (ensure_sub_board fixture)) ]
  | "masc_board_sub_board_update" ->
      `Assoc
        [
          ("sub_board_id", `String (ensure_sub_board fixture));
          ("name", `String "Tool Matrix SubBoard Updated");
        ]
  | "masc_board_sub_board_delete" ->
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
      `Assoc [ ("content", `String "tool matrix broadcast") ]
  | "keeper_task_done" ->
      (* The completion text intentionally contains the "follow-up"
         excuse pattern so the anti-rationalization gate fast-rejects
         on Gate 2 (excuse pattern) without invoking the completion-authority
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
  (* cdp_port is pinned to a closed port so the case refuses deterministically
     on every machine — a developer's live Chrome on 9222 must not turn this
     smoke case into a real browser call. *)
  | "keeper_webmcp_list" ->
    `Assoc [ "page", `String "matrix-no-such-page"; "cdp_port", `Int 59999 ]
  | "keeper_webmcp_call" ->
    `Assoc
      [ "page", `String "matrix-no-such-page"
      ; "tool", `String "masc_status"
      ; "args_json", `String "{}"
      ; "cdp_port", `Int 59999
      ]
  | other -> failwith ("missing keeper arguments contract for " ^ other)

(* Every keeper tool here may either do the work or refuse it when called with
   default arguments in a fresh workspace. Which of the two happens is not the
   contract; not falling over is. The per-tool word lists this replaced
   ("file not found", "annotation sink is not installed", ...) only ever said
   "that refusal was expected", which the typed class now says for all of them
   at once. [analyze_image] still has to refuse: its case exists to prove
   argument validation runs. *)
let keeper_expectation_for_name name =
  match name with
  | "keeper_analyze_image" -> Expect_refusal
  | _ -> Expect_success_or_refusal

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
         expectation = generic_case.expectation;
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
         expectation = Expect_success_or_refusal;
       })
  else if
    string_starts_with ~prefix:"keeper_" runtime_name
    || string_starts_with ~prefix:"tool_" runtime_name
    || String.equal runtime_name "keeper_analyze_image"
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

(* Host-level refusals: the keeper was never handed the tool, so no tool
   decided anything and there is no class to read. Textual because there is no
   typed value, not as a shortcut. *)
let host_failure_fragments =
  Generic.host_failure_fragments @ keeper_matrix_guard_fragments

(* The keeper path lowers [Tool_result.tool_failure_class] through
   [Tool_bridge.agent_core_error_class_of_tool_failure_class], which keeps the
   distinction this test needs: a refusal the tool chose arrives as
   [Deterministic] or [Transient], and only [Runtime_failure] arrives as
   [Unknown]. So the same question the MCP matrix asks is answerable here.

   [None] is a boundary that recorded no class. Treated as not-graceful: a
   smoke test that cannot tell a crash from a guard should say so rather than
   pass. *)
let is_graceful_refusal = function
  | Some Agent_core.Types.Deterministic | Some Agent_core.Types.Transient -> true
  | Some Agent_core.Types.Unknown | None -> false

let refusal_class_report = function
  | None -> "no error_class recorded"
  | Some Agent_core.Types.Deterministic -> "deterministic"
  | Some Agent_core.Types.Transient -> "transient"
  | Some Agent_core.Types.Unknown -> "unknown"

let evaluate_expectation ~name expectation = function
  | Ok _ -> (
      match expectation with
      | Expect_success | Expect_success_or_refusal -> Ok ()
      | Expect_refusal | Expect_refusal_saying _ ->
          Error (Printf.sprintf "%s expected a refusal but succeeded" name))
  | Error { Agent_core.Types.message; error_class; _ } ->
      let refused_gracefully = is_graceful_refusal error_class in
      let report = refusal_class_report error_class in
      if contains_any message host_failure_fragments then
        Error (Printf.sprintf "%s hit fatal keeper-tool failure: %s" name message)
      else (
        match expectation with
        | Expect_success ->
            Error (Printf.sprintf "%s expected success but got error: %s" name message)
        | Expect_refusal ->
            if refused_gracefully then Ok ()
            else
              Error
                (Printf.sprintf "%s refused with %s, which is a fault rather than a guard: %s"
                   name report message)
        | Expect_refusal_saying expected ->
            if not refused_gracefully then
              Error
                (Printf.sprintf "%s refused with %s, which is a fault rather than a guard: %s"
                   name report message)
            else if contains_any message [ expected ] then Ok ()
            else
              Error
                (Printf.sprintf "%s refused as expected but did not say %S: %s" name expected
                   message)
        | Expect_success_or_refusal ->
            if refused_gracefully then Ok ()
            else
              Error
                (Printf.sprintf "%s neither succeeded nor refused -- %s: %s" name report message))

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
