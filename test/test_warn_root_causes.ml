(** Harness tests for full tool visibility and atomic state writes. *)

open Alcotest
open Masc

(* ── Helpers ──────────────────────────────────────────────────── *)

let init_registry () =
  Masc_test_deps.init_unified_tool_registry ()

let file_contains_pattern file_rel pattern =
  let source_root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> root
    | None -> Sys.getcwd ()
  in
  let path = Filename.concat source_root file_rel in
  if not (Sys.file_exists path) then false
  else
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let content = In_channel.input_all ic in
        if String.length pattern = 0 then true
        else
          let re = Str.regexp_string pattern in
          (try ignore (Str.search_forward re content 0); true
           with Not_found -> false))

let file_not_contains_pattern file_rel pattern =
  not (file_contains_pattern file_rel pattern)

let string_contains text pattern =
  if String.length pattern = 0 then true
  else
    let re = Str.regexp_string pattern in
    try
      ignore (Str.search_forward re text 0);
      true
    with Not_found -> false

let require_write_ok label = function
  | Ok () -> ()
  | Error msg -> failf "%s: %s" label msg

let with_publication_recovery_registry ~registry_root f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.with_publication_recovery_registry
    ~sw
    ~fs:(Eio.Stdenv.fs env)
    ~registry_root
    f

let publication_recovery_turn_context ~registry ~keeper_name =
  Keeper_publication_recovery_availability.
    { provider = Masc_test_deps.publication_recovery_provider registry
    ; keeper_name
    }
;;

(* [agent_name] is not free-form: keeper_meta_json_parse rejects a persisted
   meta whose agent_name is not [Keeper_identity.keeper_agent_name name]
   ("keeper-<name>-agent"). Spelling it out here as [name] made every test in
   this suite that builds a meta fail at construction. Derive it the same way
   production does so a change to the canonical form breaks in one place. *)
let make_meta ?(name = "test-keeper") () : Keeper_meta_contract.keeper_meta =
  match Masc_test_deps.meta_of_json_fixture
    (`Assoc [("name", `String name);
             ("agent_name", `String (Keeper_identity.keeper_agent_name name));
             ("trace_id", `String "test-trace-warn")]) with
  | Ok meta -> meta
  | Error e -> failwith (Printf.sprintf "make_meta failed: %s" e)

let test_web_tools_are_bundle_visible () =
  ignore (init_registry ());
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc_test_web_alias_%d" (Random.int 1_000_000))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () -> try Unix.rmdir dir with _ -> ())
    (fun () ->
      let config = Workspace.default_config dir in
      let meta = make_meta ~name:"test-web-tools-visible" () in
      let ctx_snapshot =
        Keeper_context_runtime.create ~eio:false ~system_prompt:"test"
      in
      with_publication_recovery_registry ~registry_root:dir
      @@ fun publication_recovery_registry ->
      let publication_recovery =
        publication_recovery_turn_context
          ~registry:publication_recovery_registry
          ~keeper_name:meta.name
      in
      let bundle =
        Keeper_tools_oas_bundle.make_tool_bundle
          ~config ~meta ~publication_recovery ~ctx_snapshot ()
      in
      Fun.protect
        ~finally:bundle.cleanup
        (fun () ->
          let names =
            bundle.tools
            |> List.map (fun (tool : Agent_sdk.Tool.t) -> tool.schema.name)
          in
          check bool "WebSearch remains bundle-visible" true
            (List.mem "WebSearch" names);
          check bool "WebFetch remains bundle-visible" true
            (List.mem "WebFetch" names);
          check bool "Grep preferred projection is bundle-visible" true
            (List.mem "Grep" names);
          check bool "Grep internal route is not model-visible" false
            (List.mem "tool_search_files" names);
          check int
            "bundle model names are unique"
            (List.length names)
            (List.length (List.sort_uniq String.compare names))))

let test_fusion_default_descriptor_is_bundle_visible () =
  ignore (init_registry ());
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc_test_fusion_bundle_%d" (Random.int 1_000_000))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () -> try Unix.rmdir dir with _ -> ())
    (fun () ->
      let config = Workspace.default_config dir in
      let meta = make_meta ~name:"test-fusion-default-descriptor" () in
      let ctx_snapshot =
        Keeper_context_runtime.create ~eio:false ~system_prompt:"test"
      in
      with_publication_recovery_registry ~registry_root:dir
      @@ fun publication_recovery_registry ->
      let publication_recovery =
        publication_recovery_turn_context
          ~registry:publication_recovery_registry
          ~keeper_name:meta.name
      in
      let bundle =
        Keeper_tools_oas_bundle.make_tool_bundle
          ~config ~meta ~publication_recovery ~ctx_snapshot ()
      in
      Fun.protect
        ~finally:bundle.cleanup
        (fun () ->
          let names =
            bundle.tools
            |> List.map (fun (tool : Agent_sdk.Tool.t) -> tool.schema.name)
          in
          check bool "masc_fusion is in the executable OAS tool bundle" true
            (List.mem "masc_fusion" names)))

let test_bundle_exactly_matches_model_visible_descriptors () =
  ignore (init_registry ());
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc_test_complete_tool_bundle_%d" (Random.int 1_000_000))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () -> try Unix.rmdir dir with _ -> ())
    (fun () ->
      let config = Workspace.default_config dir in
      let meta = make_meta ~name:"test-complete-tool-bundle" () in
      let ctx_snapshot =
        Keeper_context_runtime.create ~eio:false ~system_prompt:"test"
      in
      with_publication_recovery_registry ~registry_root:dir
      @@ fun publication_recovery_registry ->
      let publication_recovery =
        publication_recovery_turn_context
          ~registry:publication_recovery_registry
          ~keeper_name:meta.name
      in
      let bundle =
        Keeper_tools_oas_bundle.make_tool_bundle
          ~config ~meta ~publication_recovery ~ctx_snapshot ()
      in
      Fun.protect
        ~finally:bundle.cleanup
        (fun () ->
          let expected_names =
            Keeper_tool_descriptor.model_visible_descriptors ()
            |> List.concat_map Keeper_tool_descriptor.keeper_model_names
            |> List.sort_uniq String.compare
          in
          let actual_names =
            bundle.tools
            |> List.map (fun (tool : Agent_sdk.Tool.t) -> tool.schema.name)
            |> List.sort_uniq String.compare
          in
          check
            (list string)
            "every descriptor-declared model tool is materialized exactly once"
            expected_names
            actual_names;
          check int "bundle contains no duplicate model names" (List.length actual_names)
            (List.length bundle.tools)))

let test_librarian_research_bundle_is_closed_and_read_only () =
  ignore (init_registry ());
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc_test_librarian_research_bundle_%d" (Random.int 1_000_000))
  in
  (try Unix.mkdir dir 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () ->
      try Unix.rmdir dir with
      | _ -> ())
    (fun () ->
       Eio_main.run
       @@ fun env ->
       Eio.Switch.run
       @@ fun sw ->
       let config = Workspace.default_config dir in
       let meta = make_meta ~name:"test-librarian-research-bundle" () in
       let ctx_snapshot =
         Keeper_context_runtime.create ~eio:false ~system_prompt:"test"
       in
       Masc_test_deps.with_publication_recovery_registry
         ~sw
         ~fs:(Eio.Stdenv.fs env)
         ~registry_root:dir
       @@ fun publication_recovery_registry ->
       let publication_recovery =
         publication_recovery_turn_context
           ~registry:publication_recovery_registry
           ~keeper_name:meta.name
       in
       let request : Keeper_librarian_research.request =
         { execution_id = Keeper_librarian_research.Execution_id.generate ()
         ; runtime_id = "test-runtime"
         ; frozen_system_prompt = "test"
         ; frozen_prompt = "test"
         ; frozen_input = `Assoc [ "test", `Bool true ]
         ; evidence_budget_bytes = 1024
         ; config
         ; meta
         ; publication_recovery
         ; ctx_snapshot
         ; clock = Eio.Stdenv.clock env
         ; net = Eio.Stdenv.net env
         ; continuation_channel = None
         ; raw_trace = None
         }
       in
       let actual_names, cleanup =
         Keeper_librarian_research.For_testing.tool_names_for_request request
       in
       let descriptor_contract =
         Keeper_librarian_research.For_testing.research_descriptor_contract ()
       in
       let expected_names =
         descriptor_contract
         |> List.map (fun (name, _, _) -> name)
         |> List.sort_uniq String.compare
       in
       check
         (list string)
         "research runner receives only its closed descriptor projection"
         expected_names
         (List.sort_uniq String.compare actual_names);
       check int
         "research runner bundle contains no duplicates"
         (List.length expected_names)
         (List.length actual_names);
       List.iter
         (fun (name, readonly_hint, route) ->
            check
              (option bool)
              (Printf.sprintf "%s is statically read-only" name)
              (Some true)
              readonly_hint;
            check bool
              (Printf.sprintf "%s retains a typed runtime route" name)
              true
              (String.starts_with ~prefix:"tool_" route))
         descriptor_contract;
       List.iter
         (fun name ->
            check bool
              (Printf.sprintf "%s is not representable in Librarian research" name)
              false
              (List.mem name actual_names))
         [ "Execute"
         ; "Edit"
         ; "Write"
         ; "keeper_memory_write"
         ; "keeper_surface_post"
         ; "masc_fusion"
         ; "AnalyzeImage"
         ];
       check int
         "each rejected research call records one causal result"
         (List.length actual_names)
         (Keeper_librarian_research.For_testing.invalid_request_result_callback_count
            request);
       match cleanup with
       | Keeper_librarian_research.Cleanup_succeeded -> ()
       | Cleanup_failed detail -> failf "research bundle cleanup failed: %s" detail
       | Cleanup_cancelled -> fail "research bundle cleanup was cancelled")
;;

let test_librarian_research_cleanup_contract () =
  let first_execution_id =
    Keeper_librarian_research.Execution_id.generate ()
    |> Keeper_librarian_research.Execution_id.to_string
  in
  let second_execution_id =
    Keeper_librarian_research.Execution_id.generate ()
    |> Keeper_librarian_research.Execution_id.to_string
  in
  check bool
    "generated research execution id names its phase"
    true
    (String.starts_with ~prefix:"librarian-research-" first_execution_id);
  check bool
    "generated research execution ids are distinct"
    false
    (String.equal first_execution_id second_execution_id);
  let cleanup_count = ref 0 in
  let observed = ref None in
  let value =
    Keeper_librarian_research.For_testing.protect_with_cleanup
      ~cleanup:(fun () -> incr cleanup_count)
      ~on_cleanup:(fun outcome -> observed := Some outcome)
      (fun () -> 42)
  in
  check int "success body result" 42 value;
  check int "success cleanup exactly once" 1 !cleanup_count;
  (match !observed with
   | Some Keeper_librarian_research.Cleanup_succeeded -> ()
   | _ -> fail "successful cleanup outcome was not recorded");
  let raised = ref false in
  (try
     ignore
       (Keeper_librarian_research.For_testing.protect_with_cleanup
          ~cleanup:(fun () -> incr cleanup_count)
          ~on_cleanup:(fun outcome -> observed := Some outcome)
          (fun () -> raise (Failure "research failed"))
        : unit)
   with
   | Failure detail when String.equal detail "research failed" -> raised := true
   | _ -> ());
  check bool "body failure propagated" true !raised;
  check int "failure cleanup exactly once" 2 !cleanup_count;
  let cancelled = ref false in
  (try
     ignore
       (Keeper_librarian_research.For_testing.protect_with_cleanup
          ~cleanup:(fun () -> incr cleanup_count)
          ~on_cleanup:(fun outcome -> observed := Some outcome)
          (fun () -> raise (Eio.Cancel.Cancelled (Failure "cancel research")))
        : unit)
   with
   | Eio.Cancel.Cancelled _ -> cancelled := true);
  check bool "cancellation propagated" true !cancelled;
  check int "cancellation cleanup exactly once" 3 !cleanup_count;
  let cleanup_failure = ref None in
  let value =
    Keeper_librarian_research.For_testing.protect_with_cleanup
      ~cleanup:(fun () -> raise (Failure "cleanup failed"))
      ~on_cleanup:(fun outcome -> cleanup_failure := Some outcome)
      (fun () -> 7)
  in
  check int "cleanup failure does not replace body result" 7 value;
  (match !cleanup_failure with
   | Some (Keeper_librarian_research.Cleanup_failed detail) ->
     check bool
       "cleanup failure detail retained"
       true
       (string_contains detail "cleanup failed")
   | _ -> fail "cleanup failure outcome was not recorded");
  let cleanup_reserved_propagated =
    try
      ignore
        (Keeper_librarian_research.For_testing.protect_with_cleanup
           ~cleanup:(fun () -> raise Stack_overflow)
           ~on_cleanup:(fun _ -> fail "reserved cleanup became an outcome")
           (fun () -> 9));
      false
    with
    | Stack_overflow -> true
    | _ -> false
  in
  check bool
    "reserved cleanup failure propagates"
    true
    cleanup_reserved_propagated
;;

let test_librarian_research_reserved_exceptions_propagate () =
  let assert_reserved name exception_ matches =
    let propagated =
      try
        ignore
          (Keeper_librarian_research.For_testing.internal_error_of_exception
             exception_);
        false
      with
      | caught -> matches caught
    in
    check bool name true propagated
  in
  assert_reserved "out of memory propagates" Out_of_memory
    (function Out_of_memory -> true | _ -> false);
  assert_reserved "stack overflow propagates" Stack_overflow
    (function Stack_overflow -> true | _ -> false);
  assert_reserved "break propagates" Sys.Break
    (function Sys.Break -> true | _ -> false);
  match
    Keeper_librarian_research.For_testing.internal_error_of_exception
      (Failure "ordinary research failure")
  with
  | Agent_sdk.Error.Internal detail ->
    check bool "ordinary failure is translated" true
      (string_contains detail "ordinary research failure")
  | _ -> fail "ordinary research failure used the wrong SDK error"
;;

let test_librarian_registry_receipt_excludes_raw_payloads () =
  let execution_id = Keeper_librarian_research.Execution_id.generate () in
  let receipt : Keeper_librarian_research.receipt =
    { execution_id
    ; runtime_id = "runtime-safe"
    ; frozen_system_prompt = "SECRET_SYSTEM_SENTINEL"
    ; frozen_prompt = "SECRET_PROMPT_SENTINEL"
    ; frozen_input = `Assoc [ "opaque", `String "SECRET_INPUT_SENTINEL" ]
    ; started_at = 1.0
    ; finished_at = 2.0
    ; duration_ms = 1000.0
    ; tool_names = [ "keeper_time_now" ]
    ; tool_calls = []
    ; terminal_effect = Keeper_tools_oas.Terminal_effect_open
    ; cleanup = Keeper_librarian_research.Cleanup_succeeded
    ; outcome =
        Keeper_librarian_research.Research_completed
          { evidence =
              { text = "SECRET_EVIDENCE_SENTINEL"
              ; original_bytes = 24
              ; retained_bytes = 24
              ; truncated = false
              }
          ; session_id = "session-safe"
          ; turns = 1
          ; stop_reason = Runtime_agent.Completed
          }
    ; trace_ref = None
    }
  in
  let projected =
    Keeper_librarian_research.registry_receipt_to_yojson receipt
    |> Yojson.Safe.to_string
  in
  List.iter
    (fun sentinel ->
       check bool
         (sentinel ^ " absent from long-lived projection")
         false
         (string_contains projected sentinel))
    [ "SECRET_SYSTEM_SENTINEL"
    ; "SECRET_PROMPT_SENTINEL"
    ; "SECRET_INPUT_SENTINEL"
    ; "SECRET_EVIDENCE_SENTINEL"
    ]
;;

let test_missing_current_task_reconciled_before_transition_hint () =
  ignore (init_registry ());
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc_test_stale_task_hint_%d" (Random.int 1_000_000))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () -> try Unix.rmdir dir with _ -> ())
    (fun () ->
      let config = Workspace.default_config dir in
      ignore (Workspace.init config ~agent_name:(Some "test-stale-task-hint"));
      let task_id =
        match Keeper_id.Task_id.of_string "task-1468" with
        | Ok task_id -> task_id
        | Error msg -> failf "task id parse failed: %s" msg
      in
      let meta =
        { (make_meta ~name:"test-stale-task-hint" ()) with
          current_task_id = Some task_id
        }
      in
      let ctx_snapshot =
        Keeper_context_runtime.create ~eio:false ~system_prompt:"test"
      in
      with_publication_recovery_registry ~registry_root:dir
      @@ fun publication_recovery_registry ->
      let publication_recovery =
        publication_recovery_turn_context
          ~registry:publication_recovery_registry
          ~keeper_name:meta.name
      in
      let bundle =
        Keeper_tools_oas_bundle.make_tool_bundle
          ~config ~meta ~publication_recovery ~ctx_snapshot ()
      in
      Fun.protect
        ~finally:bundle.cleanup
        (fun () ->
          let description =
            bundle.tools
            |> List.find_map (fun (tool : Agent_sdk.Tool.t) ->
                 if String.equal tool.schema.name "masc_transition"
                 then Some tool.schema.description
                 else None)
          in
          match description with
          | None -> fail "masc_transition not found in bundle"
          | Some description ->
            (* masc#26123 stopped the runtime injecting task state into tool
               descriptions: the reconciled "No task currently assigned" hint
               went with the stale "not found in backlog" one. The contract is
               now stronger than either — the description states what the tool
               does and carries no turn-specific state at all, even though this
               keeper holds a current_task_id that no backlog resolves. That
               commit updated the registry-integrity suite and missed this one,
               which no runtest target runs. *)
            check bool "no stale task hint" false
              (string_contains description "not found in backlog");
            check bool "no reconciled task hint either" false
              (string_contains description "No task currently assigned");
            (* Was pinned to the literal "Transition a task to a new status." —
               the inline string [cluster_descriptor] used to be handed. That
               string is gone: the descriptor now takes its description from
               the canonical registry, so pinning the registry's own text keeps
               the contract this case exists for (a static capability
               statement, no turn-specific state) without re-typing a 400-byte
               literal that would drift the moment the schema is edited.
               Injecting turn state would still fail here, because the injected
               text would no longer equal the registry's. *)
            let canonical =
              List.find_map
                (fun (schema : Masc_domain.tool_schema) ->
                   if String.equal schema.name "masc_transition"
                   then Some schema.description
                   else None)
                Config.raw_all_tool_schemas
            in
            (match canonical with
             | None -> fail "masc_transition missing from the canonical registry"
             | Some canonical ->
               check string "description is the registry's capability statement"
                 canonical description)))

let test_tool_bundle_does_not_emit_full_universe_assignment () =
  ignore (init_registry ());
  Tool_assignment_telemetry.reset_for_testing ();
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc_test_assignment_bundle_%d" (Random.int 1_000_000))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () -> try Unix.rmdir dir with _ -> ())
    (fun () ->
      let config = Workspace.default_config dir in
      let meta = make_meta ~name:"test-assignment-bundle" () in
      let ctx_snapshot =
        Keeper_context_runtime.create ~eio:false ~system_prompt:"test"
      in
      with_publication_recovery_registry ~registry_root:dir
      @@ fun publication_recovery_registry ->
      let publication_recovery =
        publication_recovery_turn_context
          ~registry:publication_recovery_registry
          ~keeper_name:meta.name
      in
      let bundle =
        Keeper_tools_oas_bundle.make_tool_bundle
          ~config ~meta ~publication_recovery ~ctx_snapshot ()
      in
      Fun.protect
        ~finally:bundle.cleanup
        (fun () ->
          check
            (option string)
            "bundle assembly must not claim an LLM-visible assignment"
            None
            (Tool_assignment_telemetry.find_latest_assignment_id
               ~agent_id:meta.agent_name)))

let test_tool_assignment_telemetry_is_before_turn_scoped () =
  check bool "bundle source does not emit assignment" true
    (file_not_contains_pattern
       "lib/keeper/keeper_tools_oas_bundle.ml"
       "Tool_assignment_telemetry.emit_assigned");
  check bool "legacy bundle reason removed" true
    (file_not_contains_pattern
       "lib/keeper/keeper_tools_oas_bundle.ml"
       "keeper tool bundle assembly");
  check bool "before-turn hook records computed schema filter" true
    (file_contains_pattern
       "lib/keeper/keeper_run_tools_hooks.ml"
       "record_tool_assignment ~turn ~tool_list:schema_filter ~lane");
  check bool "setup owns assignment telemetry emission" true
    (file_contains_pattern
       "lib/keeper/keeper_run_tools_setup.ml"
       "Tool_assignment_telemetry.emit_assigned")

(* ── Test 2: Atomic agent JSON writes ─────────────────────────── *)

let test_atomic_write_not_empty () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_atomic_%d" (Random.int 1_000_000)) in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let path = Filename.concat dir "test_agent.json" in
  let json =
    `Assoc [ ("name", `String "test"); ("status", `String "ok") ]
  in
  require_write_ok "atomic write" (Workspace_utils.write_json_local path json);
  let content = Fs_compat.load_file path in
  check bool "file not empty after atomic write" true
    (String.length content > 0);
  let parsed = Yojson.Safe.from_string content in
  check string "name field" "test"
    (Yojson.Safe.Util.member "name" parsed |> Yojson.Safe.Util.to_string);
  (* Verify .tmp is cleaned up *)
  check bool "no leftover .tmp" false (Sys.file_exists (path ^ ".tmp"));
  (try Unix.unlink path with _ -> ());
  (try Unix.rmdir dir with _ -> ())

(** Concurrent writes via atomic pattern must never produce empty reads. *)
let test_concurrent_atomic_writes_never_empty () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_concurrent_%d" (Random.int 1_000_000)) in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let path = Filename.concat dir "agent.json" in
  (* Seed with initial content *)
  require_write_ok "seed write"
    (Workspace_utils.write_json_local path
       (`Assoc [ ("name", `String "init") ]));
  let empty_seen = ref false in
  let iterations = 200 in
  Eio.Switch.run @@ fun sw ->
  (* Writer fiber: rapidly update the file *)
  Eio.Fiber.fork ~sw (fun () ->
    for i = 1 to iterations do
      let json =
        `Assoc [ ("name", `String (Printf.sprintf "v%d" i)) ]
      in
      require_write_ok "concurrent write" (Workspace_utils.write_json_local path json);
      Eio.Fiber.yield ()
    done);
  (* Reader fiber: read concurrently *)
  Eio.Fiber.fork ~sw (fun () ->
    for _ = 1 to iterations do
      (try
         let content = Fs_compat.load_file path in
         if String.trim content = "" then empty_seen := true
       with _ -> ());
      Eio.Fiber.yield ()
    done);
  check bool "concurrent reads never see empty file" false !empty_seen;
  (try Unix.unlink path with _ -> ());
  (try Unix.rmdir dir with _ -> ())

(* ── Test 3: Keeper/OAS failure severities on main path ─────────────── *)

let test_keeper_mainline_failures_log_at_error () =
  check bool "missing checkpoint after run logs at ERROR" true
    (file_contains_pattern "lib/keeper/keeper_agent_run_finalize_response.ml"
       {|"runtime=%s missing OAS checkpoint after run"|});
  (* The deterministic memory-bank write (and its "memory_write failed" log
     site) was removed with the bank — RFC keeper-memory-consolidation
     Stage 4. *)
  check bool "memory-bank write log site is gone" true
    (file_not_contains_pattern "lib/keeper/keeper_agent_run_post_turn_memory.ml"
       {|"memory_write failed: %s"|});
  check bool "stale episode creation failure string is absent" true
    (file_not_contains_pattern "lib/keeper/keeper_agent_run.ml"
       {|episode_create failed|})

(* ── Runner ───────────────────────────────────────────────────── *)

let () =
  run "Warn_root_causes"
    [
      ( "complete_tool_surface",
        [
          test_case "web tools are bundle visible" `Quick
            test_web_tools_are_bundle_visible;
          test_case "fusion default descriptor reaches OAS bundle" `Quick
            test_fusion_default_descriptor_is_bundle_visible;
          test_case "bundle exactly matches model-visible descriptors" `Quick
            test_bundle_exactly_matches_model_visible_descriptors;
          test_case "librarian research bundle is closed and read-only" `Quick
            test_librarian_research_bundle_is_closed_and_read_only;
          test_case "librarian research cleanup covers success error cancellation" `Quick
            test_librarian_research_cleanup_contract;
          test_case "librarian research preserves reserved exceptions" `Quick
            test_librarian_research_reserved_exceptions_propagate;
          test_case "librarian registry receipt excludes raw payloads" `Quick
            test_librarian_registry_receipt_excludes_raw_payloads;
          test_case "missing current task reconciles before transition hint" `Quick
            test_missing_current_task_reconciled_before_transition_hint;
          test_case "bundle assembly does not emit assignment" `Quick
            test_tool_bundle_does_not_emit_full_universe_assignment;
          test_case "assignment telemetry is before-turn scoped" `Quick
            test_tool_assignment_telemetry_is_before_turn_scoped;
        ] );
      ( "atomic_agent_json",
        [
          test_case "atomic write produces non-empty file" `Quick
            test_atomic_write_not_empty;
          test_case "concurrent writes never produce empty reads" `Quick
            test_concurrent_atomic_writes_never_empty;
        ] );
      ( "mainline_failure_levels",
        [
          test_case "keeper mainline failures log at error" `Quick
            test_keeper_mainline_failures_log_at_error;
        ] );
    ]
