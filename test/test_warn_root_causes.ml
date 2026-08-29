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

(* RFC-0393: the keeper meta carries one name and nothing derived from it. *)
let make_meta ?(name = "test-keeper") () : Keeper_meta_contract.keeper_meta =
  match Masc_test_deps.meta_of_json_fixture
    (`Assoc [("name", `String name);
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
        Keeper_tools_agent_core_bundle.For_testing.make_tool_bundle
          ~config ~meta ~publication_recovery ~ctx_snapshot ()
      in
      Fun.protect
        ~finally:bundle.cleanup
        (fun () ->
          let names =
            bundle.tools
            |> List.map (fun (tool : Agent_core.Tool.t) -> tool.schema.name)
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
        Keeper_tools_agent_core_bundle.For_testing.make_tool_bundle
          ~config ~meta ~publication_recovery ~ctx_snapshot ()
      in
      Fun.protect
        ~finally:bundle.cleanup
        (fun () ->
          let names =
            bundle.tools
            |> List.map (fun (tool : Agent_core.Tool.t) -> tool.schema.name)
          in
          check bool "masc_fusion is in the executable Agent Core tool bundle" true
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
        Keeper_tools_agent_core_bundle.For_testing.make_tool_bundle
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
            |> List.map (fun (tool : Agent_core.Tool.t) -> tool.schema.name)
            |> List.sort_uniq String.compare
          in
          check
            (list string)
            "every descriptor-declared model tool is materialized exactly once"
            expected_names
            actual_names;
          check int "bundle contains no duplicate model names" (List.length actual_names)
            (List.length bundle.tools);
          List.iter
            (fun (tool : Agent_core.Tool.t) ->
               let name = tool.schema.name in
               let descriptor =
                 match
                   Keeper_tool_descriptor_resolution.descriptor_for_tool_name name
                 with
                 | Some descriptor -> descriptor
                 | None -> failf "bundle tool %s has no descriptor owner" name
               in
               check bool
                 (name ^ " has an explicit Agent Core descriptor")
                 true
                 (Option.is_some (Agent_core.Tool.descriptor tool));
               (match descriptor.execution with
                | Keeper_tool_descriptor.Ordinary expected_mode ->
                  let expected_mode =
                    match expected_mode with
                    | Keeper_tool_descriptor.Serial -> Agent_core.Tool_contract.Serial
                    | Keeper_tool_descriptor.Concurrent ->
                      Agent_core.Tool_contract.Concurrent
                  in
                  check bool
                    (name ^ " execution mode matches its descriptor")
                    true
                    (Agent_core.Tool.execution_mode tool ~input:`Null = expected_mode);
                  check bool
                    (name ^ " continues after success")
                    true
                    (Agent_core.Tool.completion tool
                     = Agent_core.Tool_contract.Continue_after_success)
                | Keeper_tool_descriptor.Direct_terminal
                | Keeper_tool_descriptor.Terminal ->
                  check bool
                    (name ^ " terminal tools are serial")
                    true
                    (Agent_core.Tool.execution_mode tool ~input:`Null
                     = Agent_core.Tool_contract.Serial);
                  check bool
                    (name ^ " terminal completion preserves unknown effect outcome")
                    true
                    (Agent_core.Tool.completion tool
                     = Agent_core.Tool_contract.Terminal_after_success
                         Agent_core.Tool_contract.Effect_outcome_unknown)))
            bundle.tools))

let test_explicit_concurrent_tools_enter_one_agent_core_batch () =
  ignore (init_registry ());
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc_test_concurrent_tool_batch_%d" (Random.int 1_000_000))
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
       Masc_test_deps.with_publication_recovery_registry
         ~sw
         ~fs:(Eio.Stdenv.fs env)
         ~registry_root:dir
       @@ fun publication_recovery_registry ->
       let config = Workspace.default_config dir in
       let meta = make_meta ~name:"test-concurrent-tool-batch" () in
       let publication_recovery =
         publication_recovery_turn_context
           ~registry:publication_recovery_registry
           ~keeper_name:meta.name
       in
       let ctx_snapshot =
         Keeper_context_runtime.create ~eio:false ~system_prompt:"test"
       in
       let bundle =
         Keeper_tools_agent_core_bundle.For_testing.make_tool_bundle
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot
           ()
       in
       Fun.protect
         ~finally:bundle.cleanup
         (fun () ->
            let require_tool name =
              match
                List.find_opt
                  (fun (tool : Agent_core.Tool.t) ->
                     String.equal tool.schema.name name)
                  bundle.tools
              with
              | Some tool -> tool
              | None -> failf "missing bundle tool %s" name
            in
            let entered_count = Atomic.make 0 in
            let entered_schedules = ref [] in
            let entered_schedules_mu = Stdlib.Mutex.create () in
            let both_entered, resolve_both_entered = Eio.Promise.create () in
            let release, resolve_release = Eio.Promise.create () in
            let wrap (tool : Agent_core.Tool.t) =
              { tool with
                handler =
                  (fun execution_env _input ->
                     let invocation =
                       match Agent_core.Tool.Execution_env.invocation execution_env with
                       | Some invocation -> invocation
                       | None -> failwith "scheduled tool omitted invocation"
                     in
                     let schedule =
                       Agent_core.Tool_contract.Invocation.schedule invocation
                     in
                     Stdlib.Mutex.lock entered_schedules_mu;
                     Fun.protect
                       ~finally:(fun () -> Stdlib.Mutex.unlock entered_schedules_mu)
                       (fun () ->
                          entered_schedules := schedule :: !entered_schedules);
                     let prior = Atomic.fetch_and_add entered_count 1 in
                     if prior = 1 then Eio.Promise.resolve resolve_both_entered ();
                     Eio.Promise.await release;
                     Ok { Agent_core.Types.content = "barrier passed"; _meta = None })
              }
            in
            let tools =
              [ wrap (require_tool "keeper_time_now")
              ; wrap (require_tool "masc_board_stats")
              ]
            in
            let report = ref None in
            Eio.Time.with_timeout_exn
              (Eio.Stdenv.clock env)
              2.0
              (fun () ->
                 Eio.Fiber.both
                   (fun () ->
                      report :=
                        Some
                          (Agent_core.Agent_tools.execute_tools
                             ~context:(Agent_core.Context.create ())
                             ~tools
                             ~hooks:Agent_core.Hooks.empty
                             ~event_bus:None
                             ~tracer:Agent_core.Tracing.null
                             ~agent_name:"test-concurrent-tool-batch-agent"
                             ~turn_count:7
                             ~usage:Agent_core.Types.empty_usage
                             [ Agent_core.Types.ToolUse
                                 { id = "time-1"
                                 ; name = "keeper_time_now"
                                 ; input = `Assoc []
                                 }
                             ; Agent_core.Types.ToolUse
                                 { id = "stats-1"
                                 ; name = "masc_board_stats"
                                 ; input = `Assoc []
                                 }
                             ]))
                   (fun () ->
                      Eio.Promise.await both_entered;
                      Eio.Promise.resolve resolve_release ()));
            (match !report with
             | Some (Ok { completed_results; _ }) ->
               check int "both calls completed" 2 (List.length completed_results)
             | Some (Error _) -> fail "concurrent batch returned an execution failure"
             | None -> fail "concurrent batch returned no report");
            let schedules =
              !entered_schedules
              |> List.sort (fun
                (left : Agent_core.Tool_contract.schedule)
                (right : Agent_core.Tool_contract.schedule) ->
                Int.compare left.planned_index right.planned_index)
            in
            check int "both handlers crossed the barrier" 2 (List.length schedules);
            List.iter
              (fun (schedule : Agent_core.Tool_contract.schedule) ->
                 check int "one shared batch index" 0 schedule.batch_index;
                 check int "batch carries both calls" 2 schedule.batch_size;
                 check bool
                   "execution mode is concurrent"
                   true
                   (schedule.execution_mode = Agent_core.Tool_contract.Concurrent))
              schedules;
            check
              (list int)
              "results retain planned order"
              [ 0; 1 ]
              (List.map
                 (fun (schedule : Agent_core.Tool_contract.schedule) ->
                    schedule.planned_index)
                 schedules)))

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
        Keeper_tools_agent_core_bundle.For_testing.make_tool_bundle
          ~config ~meta ~publication_recovery ~ctx_snapshot ()
      in
      Fun.protect
        ~finally:bundle.cleanup
        (fun () ->
          let description =
            bundle.tools
            |> List.find_map (fun (tool : Agent_core.Tool.t) ->
                 if String.equal tool.schema.name "keeper_task_claim"
                 then Some tool.schema.description
                 else None)
          in
          match description with
          | None -> fail "keeper_task_claim not found in bundle"
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
            (* Subject was masc_transition until #29681 made it a transport
               alias projected by keeper_task_claim: the model sees the
               keeper_* name, so the masc_* twin is no longer in the bundle
               and the case had nothing to read. The contract under test is
               unchanged -- a bundled tool's description is a static
               capability statement.

               Was pinned to the literal "Transition a task to a new status." —
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
                   if String.equal schema.name "keeper_task_claim"
                   then Some schema.description
                   else None)
                Config.raw_all_tool_schemas
            in
            (match canonical with
             | None -> fail "keeper_task_claim missing from the canonical registry"
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
        Keeper_tools_agent_core_bundle.For_testing.make_tool_bundle
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
               ~agent_id:meta.name)))

let test_tool_assignment_telemetry_is_before_turn_scoped () =
  check bool "bundle source does not emit assignment" true
    (file_not_contains_pattern
       "lib/keeper/keeper_tools_agent_core_bundle.ml"
       "Tool_assignment_telemetry.emit_assigned");
  check bool "legacy bundle reason removed" true
    (file_not_contains_pattern
       "lib/keeper/keeper_tools_agent_core_bundle.ml"
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

(* ── Test 3: Keeper/Agent Core failure severities on main path ─────────────── *)

let test_keeper_mainline_failures_log_at_error () =
  check bool "missing checkpoint after run logs at ERROR" true
    (file_contains_pattern "lib/keeper/keeper_agent_run_finalize_response.ml"
       {|"runtime=%s missing AGENT_CORE checkpoint after run"|});
  (* The deterministic memory-bank write (and its "memory_write failed" log
     site) was removed with the bank — RFC keeper-memory-consolidation
     Stage 4. *)
  check bool "memory-bank write log site is gone" true
    (file_not_contains_pattern "lib/keeper/keeper_agent_run_post_turn_memory.ml"
       {|"memory_write failed: %s"|});
  check bool "stale episode creation failure string is absent" true
    (file_not_contains_pattern "lib/keeper/keeper_agent_run.ml"
       {|episode_create failed|})

(* ── RFC-0389: declared keeper's turn payload narrows ─────────────────────── *)

(* Replicates the wire-capture byte measure (keeper_wire_capture.ml): the
   compact JSON of the exact unredacted tools array sent to the model. *)
let bundle_schema_bytes (bundle : Keeper_tools_agent_core.tool_bundle) =
  bundle.tools
  |> List.map Agent_core.Tool.schema_to_json
  |> fun raw -> Yojson.Safe.to_string (`List raw) |> String.length
;;

let bundle_tool_count (bundle : Keeper_tools_agent_core.tool_bundle) =
  List.length bundle.tools
;;

let with_bundle ~name f =
  ignore (init_registry ());
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc_test_surface_%d" (Random.int 1_000_000))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () -> try Unix.rmdir dir with _ -> ())
    (fun () ->
      let config = Workspace.default_config dir in
      let meta = make_meta ~name () in
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
        Keeper_tools_agent_core_bundle.For_testing.make_tool_bundle
          ~config ~meta ~publication_recovery ~ctx_snapshot ()
      in
      Fun.protect ~finally:bundle.cleanup (fun () -> f bundle))

(* An undeclared keeper's turn payload keeps the full surface (RFC-0389
   default [All], pinned byte-identically by test_keeper_tool_schema_bytes);
   a declared keeper's payload narrows to its groups. This test proves the
   narrowing is real in the actual turn bundle, not just discovery JSON. *)
let test_declared_bundle_narrows_turn_payload () =
  let undeclared_count, undeclared_bytes =
    with_bundle ~name:"test-undeclared" (fun b ->
      (bundle_tool_count b, bundle_schema_bytes b))
  in
  let declared_count, declared_bytes =
    with_bundle ~name:"test-declared" (fun b ->
      (bundle_tool_count b, bundle_schema_bytes b))
  in
  check bool "undeclared keeper's payload is non-empty" true (undeclared_count > 0);
  check bool "declared keeper's payload is smaller than undeclared"
    true
    (declared_count < undeclared_count);
  check bool "declared keeper's schema bytes are smaller than undeclared"
    true
    (declared_bytes < undeclared_bytes)

(* ── Runner ───────────────────────────────────────────────────── *)

let () =
  run "Warn_root_causes"
    [
      ( "complete_tool_surface",
        [
          test_case "web tools are bundle visible" `Quick
            test_web_tools_are_bundle_visible;
          test_case "fusion default descriptor reaches Agent Core bundle" `Quick
            test_fusion_default_descriptor_is_bundle_visible;
          test_case "bundle exactly matches model-visible descriptors" `Quick
            test_bundle_exactly_matches_model_visible_descriptors;
          test_case "explicit concurrent tools enter one Agent Core batch" `Quick
            test_explicit_concurrent_tools_enter_one_agent_core_batch;
          test_case "missing current task reconciles before transition hint" `Quick
            test_missing_current_task_reconciled_before_transition_hint;
          test_case "bundle assembly does not emit assignment" `Quick
            test_tool_bundle_does_not_emit_full_universe_assignment;
          test_case "assignment telemetry is before-turn scoped" `Quick
            test_tool_assignment_telemetry_is_before_turn_scoped;
          test_case "declared keeper's turn payload narrows (RFC-0389)" `Quick
            test_declared_bundle_narrows_turn_payload;
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
