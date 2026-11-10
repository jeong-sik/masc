open Alcotest
open Masc

module Input = Server_observation_input
module Refresh = Server_observation_refresh
module Surfaces = Server_dashboard_http_execution_surfaces
module Cache = Server_dashboard_http_cache

let with_workspace f =
  Eio_main.run (fun env ->
    let previous_fs = Fs_compat.get_fs_opt () in
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let base_path = Masc_test_deps.setup_test_workspace () in
    Fun.protect ~finally:(fun () ->
      Keeper_tool_call_log.reset_for_testing ();
      Keeper_approval.Audit.For_testing.reset_store ();
      Masc_test_deps.cleanup_test_workspace base_path;
      match previous_fs with
      | Some fs -> Fs_compat.set_fs fs
      | None -> Fs_compat.clear_fs ())
      (fun () ->
        let state = Mcp_server.For_testing.create_state ~base_path in
        (* Test watchdog only; no product timeout or freshness SLA. *)
        Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10.0 (fun () ->
          f env state)))
;;

let test_source_health_deadline () =
  let deadline ?(exists = true) ?(entry_count = 1) ?coverage_gap ~now latest_ts =
    Dashboard_tool_source_freshness.next_health_change_unix ~now ~exists
      ~entry_count ~latest_ts ~freshness_slo_s:10.0 ?coverage_gap () in
  let due = match deadline ~now:105.0 (Some 100.0) with
    | Some at -> at | None -> fail "a healthy receipt lost its SLO transition" in
  check bool "strict age comparison stays healthy at the boundary" true (due > 110.0);
  let health at =
    List.assoc "health" (Dashboard_tool_source_freshness.health_fields ~now:at
      ~exists:true ~entry_count:1 ~latest_ts:(Some 100.0) ~freshness_slo_s:10.0 ()) in
  check bool "boundary is still healthy" true (health 110.0 = `String "ok");
  check bool "the returned deadline changes the existing policy" true
    (health due = `String "stale");
  List.iter (fun result -> check bool "settled source has no age-display clock" true
    (Option.is_none result))
    [ deadline ~now:due (Some 100.0)
    ; deadline ~now:100.0 None
    ; deadline ~exists:false ~now:100.0 (Some 100.0)
    ; deadline ~entry_count:0 ~now:100.0 (Some 100.0)
    ; deadline ~coverage_gap:(`Assoc []) ~now:100.0 (Some 100.0) ]
;;

let test_exact_dependency_matrix () =
  let affects = Refresh.affects Refresh.Execution_trust in
  List.iter (fun input -> check bool "actual trust input is admitted" true (affects input))
    [ Input.Keeper {keeper = "piano"; change = Input.Row}
    ; Input.Dataset Workspace_dataset_event.Runtime_metrics
    ; Input.Keeper_tool_call {keeper = "piano"}
    ; Input.Keeper_approval_audit {keeper = "piano"; event = Keeper_approval.Audit.Gate_allowed}
    ; Input.Telemetry_gap {source = Some Telemetry_unified_source.Execution_receipt; keeper = None} ];
  List.iter (fun input -> check bool "unrelated output is not a trust read" false (affects input))
    [ Input.Dataset Workspace_dataset_event.World_memory
    ; Input.Dataset Workspace_dataset_event.Play_seats
    ; Input.Dataset (Workspace_dataset_event.Dashboard_observation {topic = `Telemetry; scope = `Workspace})
    ; Input.Telemetry_sample
    ; Input.Transport_state
    ; Input.Keeper {keeper = "piano"; change = Input.Turn_preview}
    ; Input.Agent_core {keeper = Some "piano"; change = Input.Tool_called}
    ; Input.Telemetry_gap {source = Some Telemetry_unified_source.Goal_event; keeper = None}
    ; Input.Board ]
;;

let record_gap base_path =
  Telemetry_coverage_gap.record
    ~masc_root:(Common.masc_dir_from_base_path ~base_path)
    ~source:"execution_receipt" ~producer:"isolated-trust-test"
    ~durable_store:"test-receipts" ~dashboard_surface:"/api/v1/dashboard/execution-trust"
    ~stale_reason:"test-gap" ~keeper_name:"piano" ()
;;

let test_actual_cache_completion_and_scope_cell () =
  with_workspace (fun env state ->
    let config = Mcp_server.workspace_config state in
    let completed = Eio.Stream.create 1 and output_count = ref 0 in
    Eio.Switch.run (fun sw ->
      let unsubscribe = Dashboard_observation_commit.subscribe (function
        | Workspace {base_path; payload} ->
          if String.equal base_path config.base_path
             && payload.topic = `Telemetry && payload.scope = `Workspace then (
            incr output_count;
            if Eio.Stream.is_empty completed then Eio.Stream.add completed ())
        | Process _ -> ()) in
      Eio.Switch.on_release sw unsubscribe;
      Surfaces.start_execution_trust_refresh_loop ~state ~sw ~clock:(Eio.Stdenv.clock env);
      Eio.Stream.take completed;
      let retired = Surfaces.execution_trust_cache ~state in
      check int "initial isolated source has no coverage gap" 0
        (Yojson.Safe.Util.(to_int (member "coverage_gap_count" (Cache.snapshot retired).json)));
      record_gap config.base_path;
      Eio.Stream.take completed;
      let published = (Cache.snapshot (Surfaces.execution_trust_cache ~state)).json in
      let open Yojson.Safe.Util in
      check int "actual gap append reaches the production trust worker" 1
        (published |> member "coverage_gap_count" |> to_int);
      check string "completion announces the new cached answer" "coverage_gap"
        (published |> member "health" |> to_string);
      check int "source plus initial completion do not feed back" 2 !output_count;
      (match Mcp_server.set_workspace_config state config with
       | Ok () -> () | Error _ -> fail "same-path replacement failed");
      Eio.Stream.take completed;
      let current = Surfaces.execution_trust_cache ~state in
      check bool "same path replacement owns a different cache cell" true (retired != current);
      Cache.mark_cached_surface_success retired (`String "late retired answer");
      check bool "late retired result cannot replace the new scope's cache" true
        ((Cache.snapshot current).json <> `String "late retired answer")))
;;

let test_replaced_read_is_cancelled_before_new_generation () =
  with_workspace (fun env state ->
    let started = Eio.Stream.create 2 and results = Eio.Stream.create 2 in
    let never, _ = Eio.Promise.create () in
    let generation_count = ref 0 and retired = ref false and failures = ref 0 in
    Eio.Switch.run (fun sw ->
      Refresh.start ~state ~sw ~clock:(Eio.Stdenv.clock env) ~surface:Execution_trust
        ~generation:(fun ~scope ~sw:_ ->
          incr generation_count;
          let ordinal = !generation_count in
          { Refresh.config =
              { (Proactive_refresh.default_config ~label:"scope-read" ~interval_s:60.0)
                with on_failure = Some (fun _ -> incr failures) }
          ; compute = (fun () ->
              Eio.Stream.add started ordinal;
              if ordinal = 1 then
                Fun.protect ~finally:(fun () -> retired := true)
                  (fun () -> Eio.Promise.await never);
              Mcp_server.Workspace_scope_epoch.to_string scope.epoch)
          ; on_result = Eio.Stream.add results
          ; next_deadline = (fun _ -> None) });
      check int "first scope began its authoritative read" 1 (Eio.Stream.take started);
      (match Mcp_server.set_workspace_config state (Mcp_server.workspace_config state) with
       | Ok () -> () | Error _ -> fail "same-path replacement failed");
      check int "new scope begins its own initial read" 2 (Eio.Stream.take started);
      check bool "old read is cancelled before the new one is admitted" true !retired;
      check string "only the current generation can publish"
        (Mcp_server.Workspace_scope_epoch.to_string (Mcp_server.workspace_scope state).epoch)
        (Eio.Stream.take results);
      check bool "no retired answer was published" true (Eio.Stream.is_empty results);
      check int "scope cancellation is not a provider/read failure" 0 !failures))
;;

let test_actual_commit_inputs_and_listener_failure () =
  with_workspace (fun _env state ->
    let config = Mcp_server.workspace_config state in
    let other_base = Filename.concat config.base_path "other-workspace" in
    let inputs = ref [] and other_inputs = ref [] in
    Eio.Switch.run (fun sw ->
      Input.subscribe ~sw ~base_path:config.base_path (fun input -> inputs := input :: !inputs);
      Input.subscribe ~sw ~base_path:other_base (fun input -> other_inputs := input :: !other_inputs);
      let bad_gap = Telemetry_coverage_gap.subscribe_changed (fun _ -> raise Exit) in
      let bad_tool = Keeper_tool_call_log.subscribe_written (fun _ -> raise Exit) in
      let bad_audit = Keeper_approval.Audit.subscribe_written (fun _ -> raise Exit) in
      Eio.Switch.on_release sw (fun () -> bad_gap (); bad_tool (); bad_audit ());
      let gap_failures = Telemetry_coverage_gap.failed_notifications ()
      and tool_failures = Keeper_tool_call_log.failed_write_notifications ()
      and audit_failures = Keeper_approval.Audit.failed_write_notifications () in
      record_gap config.base_path;
      Keeper_tool_call_log.init ~base_path:config.base_path ();
      Keeper_tool_call_log.log_call ~keeper_name:"piano" ~tool_name:"test-tool"
        ~input:(`Assoc []) ~output_text:"test result" ~wire_outcome:Tool_result.Ok ~duration_ms:1.0 ();
      let receipt = Keeper_approval.Audit.record ~base_path:config.base_path
          ~keeper_name:"piano" ~event_type:Keeper_approval.Audit.Gate_allowed
          ~id:"isolated-audit" ~tool_name:"test-tool" () in
      check bool "listener failure preserves the typed audit receipt" true (Result.is_ok receipt.write_result);
      check bool "gap is durable despite a failed observer" true
        (Telemetry_coverage_gap.read_recent ~masc_root:(Workspace.masc_dir config) ~n:1 <> []);
      check bool "tool result is durable despite a failed observer" true
        (Option.is_some (Keeper_tool_call_log.read_latest ~keeper_name:"piano" ()));
      (match Keeper_approval.Audit.read_recent ~base_path:config.base_path
          ~keeper_name:"piano" ~n:1 () with
       | Ok rows -> check int "audit row is durable despite a failed observer" 1 (List.length rows)
       | Error error -> fail (Keeper_approval.Audit.read_error_to_string error));
      check bool "all three actual source identities reached the scoped subscriber" true
        (List.mem (Input.Telemetry_gap {source = Some Telemetry_unified_source.Execution_receipt; keeper = Some "piano"}) !inputs
         && List.mem (Input.Keeper_tool_call {keeper = "piano"}) !inputs
         && List.mem (Input.Keeper_approval_audit {keeper = "piano"; event = Keeper_approval.Audit.Gate_allowed}) !inputs);
      check int "gap notification failure is counted" (gap_failures + 1) (Telemetry_coverage_gap.failed_notifications ());
      check int "tool notification failure is counted" (tool_failures + 1) (Keeper_tool_call_log.failed_write_notifications ());
      check int "audit notification failure is counted" (audit_failures + 1) (Keeper_approval.Audit.failed_write_notifications ());
      check int "an unrelated workspace receives no input" 0 (List.length !other_inputs);
      let own_count = List.length !inputs in
      record_gap other_base;
      check int "another workspace's gap cannot wake this reader" own_count (List.length !inputs);
      check int "the exact owner of that gap receives it" 1 (List.length !other_inputs));
    let count = List.length !inputs in
    record_gap config.base_path;
    check int "normal switch release removes the source listeners" count (List.length !inputs))
;;

let test_async_tool_commit_keeps_its_store_owner () =
  with_workspace (fun _env state ->
    let config = Mcp_server.workspace_config state in
    let other_base = Filename.concat config.base_path "other-store" in
    let own = ref 0 and other = ref 0 in
    (* Hold only the test flush daemon's clock. The actual append is drained
       through its production API after init replaces the global reader. *)
    let flush_clock = Eio_mock.Clock.make () in
    Eio.Switch.run (fun sw ->
      Input.subscribe ~sw ~base_path:config.base_path (fun input ->
        if input = Input.Keeper_tool_call {keeper = "piano"} then incr own);
      Input.subscribe ~sw ~base_path:other_base (fun input ->
        if input = Input.Keeper_tool_call {keeper = "piano"} then incr other);
      Keeper_tool_call_log.init ~base_path:config.base_path ();
      Keeper_tool_call_log.start_flush_fiber ~sw ~clock:flush_clock;
      Keeper_tool_call_log.log_call ~keeper_name:"piano" ~tool_name:"original-store-tool"
        ~input:(`Assoc []) ~output_text:"original-store-result"
        ~wire_outcome:Tool_result.Ok ~duration_ms:1.0 ();
      check int "the source row is actually queued" 1 (Keeper_tool_call_log.queued_count_for_testing ());
      check int "enqueue is not a commit notification" 0 !own;
      Keeper_tool_call_log.init ~base_path:other_base ();
      (match Keeper_tool_call_log.flush_committed () with
       | Keeper_tool_call_log.All_committed -> ()
       | Keeper_tool_call_log.All_committed_with_post_commit_failures _ -> fail "isolated append cleanup failed");
      check int "the original workspace receives its actual deferred commit" 1 !own;
      check int "reinitialization cannot reassign the old row's owner" 0 !other;
      let original = Dated_jsonl.open_store
          Dated_jsonl.Store.(at (root_of_base_path ~base_path:config.base_path) Root.Tool_calls) in
      let rows = Dated_jsonl.read_recent original 1 in
      check int "the acknowledged source row is in its exact original store" 1 (List.length rows);
      check bool "the replacement reader has no such committed row" true
        (Option.is_none (Keeper_tool_call_log.read_latest ~keeper_name:"piano" ())));
    check bool "normal release removes the test daemon's timer" false
      (Eio_mock.Clock.try_advance flush_clock))
;;

let () =
  run "workspace source refresh"
    [ "policy", [test_case "receipt health deadline" `Quick test_source_health_deadline;
                  test_case "closed source dependencies" `Quick test_exact_dependency_matrix]
    ; "consumer", [test_case "actual trust cache completion and scope cell" `Quick test_actual_cache_completion_and_scope_cell;
                    test_case "replacement cancels the retired read" `Quick test_replaced_read_is_cancelled_before_new_generation;
                    test_case "actual commits preserve writer outcomes" `Quick test_actual_commit_inputs_and_listener_failure;
                    test_case "async tool commit preserves its workspace owner" `Quick test_async_tool_commit_keeps_its_store_owner] ]
;;
