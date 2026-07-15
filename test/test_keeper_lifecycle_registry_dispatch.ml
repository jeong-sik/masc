open Alcotest

module KEC = Masc.Keeper_context_runtime
module Keeper_meta_contract = Masc.Keeper_meta_contract
module Keeper_meta_json = Masc.Keeper_meta_json
module Keeper_meta_json_parse = Masc.Keeper_meta_json_parse
module Keeper_types_profile = Masc.Keeper_types_profile
module KT = Keeper_types
module KR = Masc.Keeper_registry
module KHB = Masc.Keeper_heartbeat_snapshot
module KHS = Masc.Keeper_keepalive_signal
module KST = Keeper_state_machine
module KFS = Masc.Keeper_fs
module KTS = Masc.Keeper_types_support
module P = Masc.Otel_metric_store
module Publication_scope = Masc.Keeper_publication_recovery_scope
module Publication_availability =
  Masc.Keeper_publication_recovery_availability

let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let publication_recovery_registry env sw config =
  let registry_root =
    Eio.Path.(Eio.Stdenv.fs env / Masc.Workspace.masc_root_dir config)
  in
  match
    Fs_compat.open_publication_recovery_registry
      ~sw
      ~fs:(Eio.Stdenv.fs env)
      ~registry_root
  with
  | Ok registry -> registry
  | Error error ->
    fail
      (Fs_compat.publication_recovery_registry_error_to_string error)

let write_lines path lines =
  let dir = KFS.ensure_dir (Filename.dirname path) in
  let path = Filename.concat dir (Filename.basename path) in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      List.iter
        (fun line ->
          output_string oc line;
          output_char oc '\n')
        lines)

let write_json path json =
  let dir = KFS.ensure_dir (Filename.dirname path) in
  let path = Filename.concat dir (Filename.basename path) in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc (Yojson.Safe.pretty_to_string json))

let write_keeper_toml ~base_dir name lines =
  let path =
    Filename.concat
      (Filename.concat (Filename.concat (Filename.concat base_dir ".masc") "config") "keepers")
      (name ^ ".toml")
  in
  write_lines path lines

let write_keeper_meta_json config (meta : Keeper_meta_contract.keeper_meta) =
  write_json
    (Keeper_types_profile.keeper_meta_path config meta.name)
    (Keeper_meta_json.meta_to_json meta)

let write_keeper_meta_json_for_name config name (meta : Keeper_meta_contract.keeper_meta) =
  write_json
    (Keeper_types_profile.keeper_meta_path config name)
    (Keeper_meta_json.meta_to_json meta)

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

let ensure_test_runtime =
  let initialized = ref false in
  fun () ->
    if not !initialized then (
      let path = Filename.temp_file "keeper_lifecycle_runtime_" ".toml" in
      let oc = open_out path in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () -> output_string oc test_runtime_toml);
      Fun.protect
        ~finally:(fun () ->
          try Sys.remove path with
          | Sys_error _ -> ())
        (fun () ->
          match Runtime.init_default ~config_path:path with
          | Ok () -> initialized := true
          | Error msg -> fail msg))

let persistence_read_drop_total ~surface ~reason =
  P.metric_value_or_zero P.metric_persistence_read_drops
    ~labels:[("surface", surface); ("reason", reason)]
    ()

let check_persistence_read_drop_delta ~surface ~reason ~before ~delta =
  check (float 0.0001)
    (Printf.sprintf "%s/%s persistence read drops" surface reason)
    (before +. float_of_int delta)
    (persistence_read_drop_total ~surface ~reason)

let make_keeper_meta ?(name = "keeper-lifecycle-test")
    ?(trace_id = "trace-keeper-lifecycle") () =
  ensure_test_runtime ();
  match
    Keeper_meta_json_parse.meta_of_json
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String name);
          ("trace_id", `String trace_id);
          ("last_model_used", `String "llama:auto");
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json failed: " ^ err)

let base_lifecycle ~(meta : Keeper_meta_contract.keeper_meta) : KEC.post_turn_lifecycle =
  {
    updated_meta = meta;
    checkpoint = None;
    handoff_json = None;
    handoff_attempted = false;
    handoff_failure_reason = None;
    compaction =
      {
        attempted = false;
        applied = false;
        started_dispatched = false;
        failure_reason = None;
        trigger = None;
        decision = KEC.Not_requested;
    };
    turn_generation = meta.runtime.generation;
    checkpoint_bytes = 0;
    message_count = 0;
  }

let test_registry_rejects_meta_name_mismatch_update () =
  let base_dir = temp_dir "keeper_lifecycle_registry_meta_mismatch" in
  Fun.protect
    ~finally:(fun () ->
      KR.clear ();
      cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      KR.clear ();
      let config = Masc.Workspace.default_config base_dir in
      let meta = make_keeper_meta ~name:"keeper-registry-meta-mismatch" () in
      ignore (KR.register ~base_path:config.base_path meta.name meta);
      let bad_meta = { meta with name = "wrong-keeper-name" } in
      KR.update_meta ~base_path:config.base_path meta.name bad_meta;
      match KR.get ~base_path:config.base_path meta.name with
      | Some entry ->
          check string "registry keeps original meta name" meta.name entry.meta.name
      | None -> fail "expected registered keeper after rejected meta update")

let test_registry_canonicalizes_mismatched_meta_on_register () =
  let base_dir = temp_dir "keeper_lifecycle_registry_register_repair" in
  Fun.protect
    ~finally:(fun () ->
      KR.clear ();
      cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      KR.clear ();
      let config = Masc.Workspace.default_config base_dir in
      let registry_name = "keeper-registry-register-repair" in
      let bad_meta =
        { (make_keeper_meta ~name:"wrong-register-name" ()) with agent_name = "" }
      in
      ignore (KR.register ~base_path:config.base_path registry_name bad_meta);
      match KR.get ~base_path:config.base_path registry_name with
      | Some entry ->
          check string "registry repairs meta name" registry_name entry.meta.name;
          check string "registry repairs empty agent name"
            (Masc.Keeper_identity.keeper_agent_name registry_name)
            entry.meta.agent_name
      | None -> fail "expected registered keeper after canonical register repair")

let test_registry_reload_meta_from_disk_repairs_stale_meta () =
  let base_dir = temp_dir "keeper_lifecycle_registry_meta_reload" in
  Fun.protect
    ~finally:(fun () ->
      KR.clear ();
      cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      KR.clear ();
      let config = Masc.Workspace.default_config base_dir in
      let name = "keeper-registry-meta-reload" in
      write_keeper_toml
        ~base_dir
        name
        [ "[keeper]"
        ; {|sandbox_profile = "local"|}
        ; {|instructions = "fresh instructions"|}
        ];
      let persisted_meta = make_keeper_meta ~name () in
      let stale_meta = { persisted_meta with instructions = "stale instructions" } in
      ignore (KR.register ~base_path:config.base_path name stale_meta);
      write_keeper_meta_json_for_name config name persisted_meta;
      match KR.reload_meta_from_disk ~base_path:config.base_path name with
      | Ok (Some entry) ->
          check string "reload applies base-path TOML instructions" "fresh instructions"
            entry.meta.instructions
      | Ok None -> fail "expected reload to update registered keeper"
      | Error msg -> fail ("reload_meta_from_disk failed: " ^ msg))

let test_dispatch_keeper_phase_event_uses_workspace_base_path () =
  let base_dir = temp_dir "keeper_lifecycle_registry_phase" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      KR.clear ();
      let config = Masc.Workspace.default_config base_dir in
      let meta = make_keeper_meta ~name:"keeper-phase-regression" () in
      ignore (KR.register ~base_path:config.base_path meta.name meta);
      KEC.dispatch_keeper_phase_event
        ~config
        ~origin:KR.Post_turn_lifecycle
        ~keeper_name:meta.name
        KST.Compaction_started;
      match KR.get ~base_path:config.base_path meta.name with
      | Some entry ->
          check string "compaction start reaches registry" "compacting"
            (KST.phase_to_string entry.phase)
      | None -> fail "expected registered keeper after compaction dispatch")

let test_dispatch_post_turn_lifecycle_events_uses_workspace_base_path () =
  let base_dir = temp_dir "keeper_lifecycle_registry_outcome" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      KR.clear ();
      let config = Masc.Workspace.default_config base_dir in
      let meta = make_keeper_meta ~name:"keeper-outcome-regression" () in
      ignore (KR.register ~base_path:config.base_path meta.name meta);
      KEC.dispatch_keeper_phase_event
        ~config
        ~origin:KR.Post_turn_lifecycle
        ~keeper_name:meta.name
        KST.Compaction_started;
      let lifecycle =
        {
          (base_lifecycle ~meta) with
          compaction =
            {
              attempted = true;
              applied = true;
              started_dispatched = true;
              failure_reason = None;
              trigger = Some Compaction_trigger.Manual;
              decision = KEC.Applied Compaction_trigger.Manual;
            };
        }
      in
      KEC.dispatch_post_turn_lifecycle_events
        ~config
        ~keeper_name:meta.name
        lifecycle;
      match KR.get ~base_path:config.base_path meta.name with
      | Some entry ->
          check string "compaction completion reaches registry" "running"
            (KST.phase_to_string entry.phase)
      | None -> fail "expected registered keeper after lifecycle dispatch")

let test_post_turn_compaction_runs_from_failing_health_lane () =
  let base_dir = temp_dir "keeper_lifecycle_registry_failing_compaction" in
  Fun.protect
    ~finally:(fun () ->
      KR.clear ();
      cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      KR.clear ();
      let config = Masc.Workspace.default_config base_dir in
      let meta = make_keeper_meta ~name:"keeper-failing-compaction" () in
      ignore (KR.register ~base_path:config.base_path meta.name meta);
      KEC.dispatch_keeper_phase_event
        ~config
        ~keeper_name:meta.name
        (KST.Heartbeat_failed { consecutive = 1 });
      (match KR.get ~base_path:config.base_path meta.name with
       | Some entry ->
           check string "heartbeat failure reaches failing" "failing"
             (KST.phase_to_string entry.phase)
       | None -> fail "expected registered keeper after heartbeat dispatch");
      KEC.dispatch_keeper_phase_event
        ~config
        ~origin:KR.Post_turn_lifecycle
        ~keeper_name:meta.name
        KST.Compaction_started;
      (match KR.get ~base_path:config.base_path meta.name with
       | Some entry ->
           check string "post-turn compaction starts while failing" "compacting"
             (KST.phase_to_string entry.phase)
       | None -> fail "expected registered keeper after compaction start");
      let lifecycle =
        {
          (base_lifecycle ~meta) with
          compaction =
            {
              attempted = true;
              applied = true;
              started_dispatched = true;
              failure_reason = None;
              trigger = Some Compaction_trigger.Manual;
              decision = KEC.Applied Compaction_trigger.Manual;
            };
        }
      in
      KEC.dispatch_post_turn_lifecycle_events
        ~config
        ~keeper_name:meta.name
        lifecycle;
      match KR.get ~base_path:config.base_path meta.name with
      | Some entry ->
          check string "compaction completion preserves failing health lane" "failing"
            (KST.phase_to_string entry.phase)
      | None -> fail "expected registered keeper after compaction completion")

let test_compaction_completion_without_started_is_nonfatal () =
  let base_dir = temp_dir "keeper_lifecycle_registry_missing_start" in
  Fun.protect
    ~finally:(fun () ->
      KR.clear ();
      cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      KR.clear ();
      let config = Masc.Workspace.default_config base_dir in
      let meta = make_keeper_meta ~name:"keeper-missing-compaction-start" () in
      ignore (KR.register ~base_path:config.base_path meta.name meta);
      let labels =
        [ ("keeper", meta.name); ("event", "compaction_completed") ]
      in
      let before =
        Masc.Otel_metric_store.get_metric_value
          Keeper_metrics.(to_string LifecycleDispatchRejections)
          ~labels ()
        |> Option.value ~default:0.0
      in
      let lifecycle =
        {
          (base_lifecycle ~meta) with
          compaction =
            {
              attempted = true;
              applied = true;
              started_dispatched = true;
              failure_reason = None;
              trigger = Some Compaction_trigger.Manual;
              decision = KEC.Applied Compaction_trigger.Manual;
            };
        }
      in
      KEC.dispatch_post_turn_lifecycle_events
        ~config
        ~keeper_name:meta.name
        lifecycle;
      let after =
        Masc.Otel_metric_store.get_metric_value
          Keeper_metrics.(to_string LifecycleDispatchRejections)
          ~labels ()
        |> Option.value ~default:0.0
      in
      check bool "missing-start completion rejection is counted" true (after > before);
      match KR.get ~base_path:config.base_path meta.name with
      | Some entry ->
          check string "missing-start completion leaves phase unchanged" "running"
            (KST.phase_to_string entry.phase)
      | None -> fail "expected registered keeper after rejected completion")

let test_post_turn_compaction_restarts_after_done_stage () =
  let base_dir = temp_dir "keeper_lifecycle_registry_repeat_compaction" in
  Fun.protect
    ~finally:(fun () ->
      KR.clear ();
      cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      KR.clear ();
      let config = Masc.Workspace.default_config base_dir in
      let meta = make_keeper_meta ~name:"keeper-repeat-compaction" () in
      ignore (KR.register ~base_path:config.base_path meta.name meta);
      let lifecycle =
        {
          (base_lifecycle ~meta) with
          compaction =
            {
              attempted = true;
              applied = true;
              started_dispatched = true;
              failure_reason = None;
              trigger = Some Compaction_trigger.Manual;
              decision = KEC.Applied Compaction_trigger.Manual;
            };
        }
      in
      let run_compaction label =
        KEC.dispatch_keeper_phase_event
          ~config
          ~origin:KR.Post_turn_lifecycle
          ~keeper_name:meta.name
          KST.Compaction_started;
        (match KR.get ~base_path:config.base_path meta.name with
         | Some entry ->
             check string (label ^ " start reaches compacting") "compacting"
               (KST.phase_to_string entry.phase)
         | None -> fail "expected registered keeper after compaction start");
        KEC.dispatch_post_turn_lifecycle_events
          ~config
          ~keeper_name:meta.name
          lifecycle;
        match KR.get ~base_path:config.base_path meta.name with
        | Some entry ->
            check string (label ^ " completion returns running") "running"
              (KST.phase_to_string entry.phase)
        | None -> fail "expected registered keeper after compaction completion"
      in
      run_compaction "first";
      run_compaction "second")

let test_dispatch_keeper_phase_event_rejects_unscoped_lifecycle_event () =
  let base_dir = temp_dir "keeper_lifecycle_registry_origin_guard" in
  Fun.protect
    ~finally:(fun () ->
      KR.clear ();
      cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      KR.clear ();
      let config = Masc.Workspace.default_config base_dir in
      let meta = make_keeper_meta ~name:"keeper-origin-guard" () in
      ignore (KR.register ~base_path:config.base_path meta.name meta);
      let labels =
        [ ("keeper", meta.name); ("event", "compaction_started") ]
      in
      let before =
        Masc.Otel_metric_store.get_metric_value
          Keeper_metrics.(to_string LifecycleDispatchRejections)
          ~labels ()
        |> Option.value ~default:0.0
      in
      KEC.dispatch_keeper_phase_event
        ~config
        ~keeper_name:meta.name
        KST.Compaction_started;
      let after =
        Masc.Otel_metric_store.get_metric_value
          Keeper_metrics.(to_string LifecycleDispatchRejections)
          ~labels ()
        |> Option.value ~default:0.0
      in
      check bool "origin guard rejection metric increments" true (after > before);
      match KR.get ~base_path:config.base_path meta.name with
      | Some entry ->
          check string "unscoped compaction start is rejected" "running"
            (KST.phase_to_string entry.phase)
      | None -> fail "expected registered keeper after rejected lifecycle dispatch")

let test_dispatch_keeper_phase_event_rejection_increments_metric () =
  let base_dir = temp_dir "keeper_lifecycle_registry_rejection" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Masc.Workspace.default_config base_dir in
      let labels =
        [ ("keeper", "missing-keeper"); ("event", "compaction_started") ]
      in
      let before =
        Masc.Otel_metric_store.get_metric_value
          Keeper_metrics.(to_string LifecycleDispatchRejections)
          ~labels ()
        |> Option.value ~default:0.0
      in
      (match
         KEC.dispatch_keeper_phase_event_result
           ~config
           ~keeper_name:"missing-keeper"
           KST.Compaction_started
       with
       | Error (KEC.Transition_rejected _) -> ()
       | Error (KEC.Compaction_invariant_violation _) ->
         fail "missing keeper must be a transition rejection"
       | Ok () -> fail "missing keeper lifecycle dispatch unexpectedly succeeded");
      let after =
        Masc.Otel_metric_store.get_metric_value
          Keeper_metrics.(to_string LifecycleDispatchRejections)
          ~labels ()
        |> Option.value ~default:0.0
      in
      check bool "rejection metric increments" true (after > before))

let test_keepalive_dispatch_event_rejection_increments_metric () =
  let base_dir = temp_dir "keeper_lifecycle_keepalive_rejection" in
  Fun.protect
    ~finally:(fun () ->
      KR.clear ();
      cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      KR.clear ();
      let config = Masc.Workspace.default_config base_dir in
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = "test-operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
          publication_recovery_provider =
            Publication_availability.constant
              Publication_availability.Non_runtime;
        }
      in
      let labels =
        [ ("keeper", "missing-keeper"); ("reason", "invalid_transition") ]
      in
      let before =
        Masc.Otel_metric_store.get_metric_value
          Keeper_metrics.(to_string DispatchEventFailures)
          ~labels ()
        |> Option.value ~default:0.0
      in
      KHS.dispatch_keepalive_event
        ~ctx
        ~keeper_name:"missing-keeper"
        KST.Compaction_started;
      let after =
        Masc.Otel_metric_store.get_metric_value
          Keeper_metrics.(to_string DispatchEventFailures)
          ~labels ()
        |> Option.value ~default:0.0
      in
      check bool "keepalive registry rejection metric increments" true
        (after > before))

let test_publication_recovery_turn_resolution_is_filesystem_idle () =
  let base_dir = temp_dir "keeper_publication_recovery_scope" in
  Fun.protect
    ~finally:(fun () ->
      KR.clear ();
      cleanup_dir base_dir)
    (fun () ->
      KR.clear ();
      let config = Masc.Workspace.default_config base_dir in
      let keeper_name = "publication-scope-exact-lane" in
      let meta = make_keeper_meta ~name:keeper_name () in
      let entry = KR.register ~base_path:config.base_path keeper_name meta in
      let provider_reads = Atomic.make 0 in
      let provider () =
        Atomic.incr provider_reads;
        Publication_availability.Non_runtime
      in
      match
        Publication_scope.resolve_turn_resources
          ~provider
          ~base_path:config.base_path
          ~keeper_name
      with
      | Error failure -> fail (Publication_scope.failure_to_string failure)
      | Ok resources ->
        check bool "turn resolves exact registry entry" true
          (resources.entry == entry);
        check string
          "turn retains exact publication owner"
          keeper_name
          resources.publication_recovery.keeper_name;
        check bool
          "turn retains live provider"
          true
          (resources.publication_recovery.provider == provider);
        check int "turn resolution performs no provider or FS acquisition" 0
          (Atomic.get provider_reads))

let test_publication_recovery_scope_preserves_typed_lookup_failures () =
  let base_dir = temp_dir "keeper_publication_recovery_failures" in
  Fun.protect
    ~finally:(fun () ->
      KR.clear ();
      cleanup_dir base_dir)
    (fun () ->
      KR.clear ();
      let config = Masc.Workspace.default_config base_dir in
      let keeper_name = "publication-scope-failures" in
      let provider =
        Publication_availability.constant Publication_availability.Non_runtime
      in
      let expect_failure label expected = function
        | Error failure when expected failure -> ()
        | Error failure ->
          failf
            "%s returned wrong failure: %s"
            label
            (Publication_scope.failure_to_string failure)
        | Ok _ -> failf "%s unexpectedly resolved turn resources" label
      in
      expect_failure
        "missing keeper entry"
        (function
          | Publication_scope.Registry_entry_not_found
              { base_path; keeper_name = missing_name } ->
            String.equal base_path config.base_path
            && String.equal missing_name keeper_name
          | _ -> false)
        (Publication_scope.resolve_turn_resources
           ~provider
           ~base_path:config.base_path
           ~keeper_name);
      let entry =
        KR.register
          ~base_path:config.base_path
          keeper_name
          (make_keeper_meta ~name:keeper_name ())
      in
      let corrupted =
        { entry with
          meta =
            { entry.meta with
              runtime = { entry.meta.runtime with generation = -1 }
            }
        }
      in
      KR.For_testing.unsafe_put_entry
        ~base_path:config.base_path
        keeper_name
        corrupted;
      expect_failure
        "unhealthy keeper entry"
        (function
          | Publication_scope.Registry_entry_unhealthy
              (KR.Required_field_missing { field }) ->
            String.equal field "generation"
          | _ -> false)
        (Publication_scope.resolve_turn_resources
           ~provider
           ~base_path:config.base_path
           ~keeper_name))

let () =
  run "keeper_lifecycle_registry_dispatch"
    [
      ( "registry_dispatch",
        [
          test_case "phase event uses workspace base_path" `Quick
            test_dispatch_keeper_phase_event_uses_workspace_base_path;
          test_case "post-turn lifecycle events use workspace base_path" `Quick
            test_dispatch_post_turn_lifecycle_events_uses_workspace_base_path;
          test_case "post-turn compaction runs from failing health lane" `Quick
            test_post_turn_compaction_runs_from_failing_health_lane;
          test_case "compaction completion without started is nonfatal" `Quick
            test_compaction_completion_without_started_is_nonfatal;
          test_case "post-turn compaction restarts after done stage" `Quick
            test_post_turn_compaction_restarts_after_done_stage;
          test_case "unscoped lifecycle event is rejected" `Quick
            test_dispatch_keeper_phase_event_rejects_unscoped_lifecycle_event;
          test_case "phase event rejection increments metric" `Quick
            test_dispatch_keeper_phase_event_rejection_increments_metric;
          test_case "keepalive event rejection increments metric" `Quick
            test_keepalive_dispatch_event_rejection_increments_metric;
          test_case "publication recovery turn resolution is filesystem idle" `Quick
            test_publication_recovery_turn_resolution_is_filesystem_idle;
          test_case "publication recovery scope preserves typed lookup failures" `Quick
            test_publication_recovery_scope_preserves_typed_lookup_failures;
          test_case "registry rejects mismatched meta update" `Quick
            test_registry_rejects_meta_name_mismatch_update;
          test_case "registry canonicalizes mismatched meta on register" `Quick
            test_registry_canonicalizes_mismatched_meta_on_register;
          test_case "registry reload repairs stale meta from disk" `Quick
            test_registry_reload_meta_from_disk_repairs_stale_meta;
        ] );
    ]
