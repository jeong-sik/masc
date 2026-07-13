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
        decision = KEC.Blocked_below_thresholds;
        before_tokens = 0;
        after_tokens = 0;
        saved_tokens = 0;
      };
    turn_generation = meta.runtime.generation;
    context_ratio = 0.0;
    context_tokens = 0;
    context_max = 0;
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
        [ "[keeper]"; {|sandbox_profile = "local"|}; {|goal = "fresh goal"|} ];
      let persisted_meta = make_keeper_meta ~name () in
      let stale_meta = { persisted_meta with goal = "stale goal" } in
      ignore (KR.register ~base_path:config.base_path name stale_meta);
      write_keeper_meta_json_for_name config name persisted_meta;
      match KR.reload_meta_from_disk ~base_path:config.base_path name with
      | Ok (Some entry) ->
          check string "reload applies base-path TOML goal" "fresh goal"
            entry.meta.goal
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
              before_tokens = 42;
              after_tokens = 21;
              saved_tokens = 21;
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
              before_tokens = 42;
              after_tokens = 21;
              saved_tokens = 21;
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
        [ ("keeper", meta.name); ("event", "compaction_completed(42->21)") ]
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
              before_tokens = 42;
              after_tokens = 21;
              saved_tokens = 21;
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
      let lifecycle before_tokens after_tokens =
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
              before_tokens;
              after_tokens;
              saved_tokens = before_tokens - after_tokens;
            };
        }
      in
      let run_compaction label before_tokens after_tokens =
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
          (lifecycle before_tokens after_tokens);
        match KR.get ~base_path:config.base_path meta.name with
        | Some entry ->
            check string (label ^ " completion returns running") "running"
              (KST.phase_to_string entry.phase)
        | None -> fail "expected registered keeper after compaction completion"
      in
      run_compaction "first" 42 21;
      run_compaction "second" 84 42)

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
      KEC.dispatch_keeper_phase_event
        ~config
        ~keeper_name:"missing-keeper"
        KST.Compaction_started;
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

let test_heartbeat_history_fallback_counts_malformed_rows () =
  let base_dir = temp_dir "keeper_lifecycle_heartbeat_history_drops" in
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
      ignore (Masc.Workspace.init config ~agent_name:None);
      let meta =
        make_keeper_meta
          ~name:"keeper-heartbeat-history-drop"
          ~trace_id:"trace-heartbeat-history-drop"
          ()
      in
      ignore (KR.register ~base_path:config.base_path meta.name meta);
      let trace_id =
        Keeper_id.Trace_id.to_string meta.runtime.trace_id
      in
      let history_path = KTS.keeper_history_path config trace_id in
      write_lines history_path
        [
          {|{"role":"user","content":"keep continuity","source":"user"}|};
          "[]";
          "{not-json";
        ];
      let surface = "keeper_heartbeat_history" in
      let entry_reason = "entry_load_error" in
      let invalid_reason = "invalid_payload" in
      let before_entry =
        persistence_read_drop_total ~surface ~reason:entry_reason
      in
      let before_invalid =
        persistence_read_drop_total ~surface ~reason:invalid_reason
      in
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = "test-operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      KHB.write_heartbeat_snapshot
        ~ctx
        ~meta_current:meta
        ~now_ts:(Time_compat.now ())
        ~consecutive_hb_failures:0
        ~timing_ring:[||]
        ~timing_filled:0;
      check_persistence_read_drop_delta ~surface ~reason:entry_reason
        ~before:before_entry ~delta:1;
      check_persistence_read_drop_delta ~surface ~reason:invalid_reason
        ~before:before_invalid ~delta:2)

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
          test_case "registry rejects mismatched meta update" `Quick
            test_registry_rejects_meta_name_mismatch_update;
          test_case "registry canonicalizes mismatched meta on register" `Quick
            test_registry_canonicalizes_mismatched_meta_on_register;
          test_case "registry reload repairs stale meta from disk" `Quick
            test_registry_reload_meta_from_disk_repairs_stale_meta;
          test_case "heartbeat history fallback counts malformed rows" `Quick
            test_heartbeat_history_fallback_counts_malformed_rows;
        ] );
    ]
