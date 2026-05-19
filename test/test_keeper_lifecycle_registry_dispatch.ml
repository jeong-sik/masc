open Alcotest

module KEC = Masc_mcp.Keeper_exec_context
module KT = Masc_mcp.Keeper_types
module KR = Masc_mcp.Keeper_registry
module KHB = Masc_mcp.Keeper_heartbeat_snapshot
module KHS = Masc_mcp.Keeper_keepalive_signal
module KST = Masc_mcp.Keeper_state_machine
module P = Masc_mcp.Prometheus

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
  KT.mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      List.iter
        (fun line ->
          output_string oc line;
          output_char oc '\n')
        lines)

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
  match
    KT.meta_of_json
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String name);
          ("trace_id", `String trace_id);
          ("cascade_name", `String Masc_mcp.(Keeper_config.default_cascade_name ()));
          ("last_model_used", `String "llama:auto");
          ("sandbox_profile", `String "local");
          ("network_mode", `String "inherit");
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json failed: " ^ err)

let base_lifecycle ~(meta : KT.keeper_meta) : KEC.post_turn_lifecycle =
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

let test_dispatch_keeper_phase_event_uses_room_base_path () =
  let base_dir = temp_dir "keeper_lifecycle_registry_phase" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      KR.clear ();
      let config = Masc_mcp.Coord.default_config base_dir in
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

let test_dispatch_post_turn_lifecycle_events_uses_room_base_path () =
  let base_dir = temp_dir "keeper_lifecycle_registry_outcome" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      KR.clear ();
      let config = Masc_mcp.Coord.default_config base_dir in
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
      let config = Masc_mcp.Coord.default_config base_dir in
      let meta = make_keeper_meta ~name:"keeper-origin-guard" () in
      ignore (KR.register ~base_path:config.base_path meta.name meta);
      let labels =
        [ ("keeper", meta.name); ("event", "compaction_started") ]
      in
      let before =
        Masc_mcp.Prometheus.get_metric_value
          Masc_mcp.Keeper_metrics.metric_keeper_lifecycle_dispatch_rejections
          ~labels ()
        |> Option.value ~default:0.0
      in
      KEC.dispatch_keeper_phase_event
        ~config
        ~keeper_name:meta.name
        KST.Compaction_started;
      let after =
        Masc_mcp.Prometheus.get_metric_value
          Masc_mcp.Keeper_metrics.metric_keeper_lifecycle_dispatch_rejections
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
      let config = Masc_mcp.Coord.default_config base_dir in
      let labels =
        [ ("keeper", "missing-keeper"); ("event", "compaction_started") ]
      in
      let before =
        Masc_mcp.Prometheus.get_metric_value
          Masc_mcp.Keeper_metrics.metric_keeper_lifecycle_dispatch_rejections
          ~labels ()
        |> Option.value ~default:0.0
      in
      KEC.dispatch_keeper_phase_event
        ~config
        ~keeper_name:"missing-keeper"
        KST.Compaction_started;
      let after =
        Masc_mcp.Prometheus.get_metric_value
          Masc_mcp.Keeper_metrics.metric_keeper_lifecycle_dispatch_rejections
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
      let config = Masc_mcp.Coord.default_config base_dir in
      let ctx : _ KT.context =
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
        Masc_mcp.Prometheus.get_metric_value
          Masc_mcp.Keeper_metrics.metric_keeper_dispatch_event_failures
          ~labels ()
        |> Option.value ~default:0.0
      in
      KHS.dispatch_keepalive_event
        ~ctx
        ~keeper_name:"missing-keeper"
        KST.Compaction_started;
      let after =
        Masc_mcp.Prometheus.get_metric_value
          Masc_mcp.Keeper_metrics.metric_keeper_dispatch_event_failures
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
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:None);
      let meta =
        make_keeper_meta
          ~name:"keeper-heartbeat-history-drop"
          ~trace_id:"trace-heartbeat-history-drop"
          ()
      in
      ignore (KR.register ~base_path:config.base_path meta.name meta);
      let trace_id =
        Masc_mcp.Keeper_id.Trace_id.to_string meta.runtime.trace_id
      in
      let history_path = KT.keeper_history_path config trace_id in
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
      let ctx : _ KT.context =
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
        ~before:before_invalid ~delta:1)

let () =
  run "keeper_lifecycle_registry_dispatch"
    [
      ( "registry_dispatch",
        [
          test_case "phase event uses room base_path" `Quick
            test_dispatch_keeper_phase_event_uses_room_base_path;
          test_case "post-turn lifecycle events use room base_path" `Quick
            test_dispatch_post_turn_lifecycle_events_uses_room_base_path;
          test_case "unscoped lifecycle event is rejected" `Quick
            test_dispatch_keeper_phase_event_rejects_unscoped_lifecycle_event;
          test_case "phase event rejection increments metric" `Quick
            test_dispatch_keeper_phase_event_rejection_increments_metric;
          test_case "keepalive event rejection increments metric" `Quick
            test_keepalive_dispatch_event_rejection_increments_metric;
          test_case "heartbeat history fallback counts malformed rows" `Quick
            test_heartbeat_history_fallback_counts_malformed_rows;
        ] );
    ]
