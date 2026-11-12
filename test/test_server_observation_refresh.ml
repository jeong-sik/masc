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
    ; Input.Operator_judgment Operator_judgment.Command_namespace
    ; Input.Tool_host_attention
    ; Input.Board ]
;;

let test_execution_dependency_matrix () =
  let affects = Refresh.affects Refresh.Execution in
  List.iter (fun input -> check bool "execution source is admitted" true (affects input))
    [ Input.Workspace_agent_signal {agent = "source-agent"}
    ; Input.Workspace_messages {request_id = "original-message";
        mention_delivery = Masc_domain.Mention_passive}
    ; Input.Execution_invalidated; Input.Board
    ; Input.Keeper_tool_call {keeper = "piano"}
    ; Input.Dataset Workspace_dataset_event.Goals ];
  List.iter (fun input -> check bool "unread surface cannot wake execution" false (affects input))
    [ Input.Dataset Workspace_dataset_event.World_memory
    ; Input.Dataset Workspace_dataset_event.Play_seats
    ; Input.Dataset (Workspace_dataset_event.Dashboard_observation {topic = `Telemetry; scope = `Workspace})
    ; Input.Agent_core {keeper = Some "piano"; change = Input.Tool_called}
    ; Input.Telemetry_sample
    ; Input.Operator_judgment Operator_judgment.Command_namespace
    ; Input.Tool_host_attention ]
;;

let test_execution_owner_rejects_a_retired_request () =
  with_workspace (fun _env state ->
    let config = Mcp_server.workspace_config state in
    let old_scope = Mcp_server.workspace_scope state in
    let old_owner = Surfaces.For_testing.owner_for_state ~state in
    let old_cache = Surfaces.execution_cache ~state in
    let initial = Surfaces.For_testing.begin_execution_attempt ~owner:old_owner () in
    check bool "old scope originally had a real successful publication" true
      (Surfaces.For_testing.publish_execution_attempt_success initial (`Assoc ["marker", `String "old-good"]));
    let old_generation = Yojson.Safe.Util.(
      (Cache.snapshot old_cache).json |> member "execution_publication_generation" |> to_int) in
    let old_attempt = Surfaces.For_testing.begin_execution_attempt ~owner:old_owner () in
    (match Mcp_server.set_workspace_config state config with
     | Ok () -> () | Error _ -> fail "same-path scope replacement failed");
    let current_owner = Surfaces.For_testing.owner_for_state ~state in
    let current_cache = Surfaces.execution_cache ~state in
    check bool "same-path scope owns a different execution cell" true (old_cache != current_cache);
    let current_attempt = Surfaces.For_testing.begin_execution_attempt ~owner:current_owner () in
    check bool "current publication is admitted" true
      (Surfaces.For_testing.publish_execution_attempt_success current_attempt
        (`Assoc ["marker", `String "current-scope"]));
    check string "Goal/header process publication identity remains unchanged"
      Surfaces.execution_publication_epoch Yojson.Safe.Util.(
        (Cache.snapshot current_cache).json |> member "execution_publication_epoch" |> to_string);
    check bool "same-process scope replacement advances the generation floor" true
      (Yojson.Safe.Util.((Cache.snapshot current_cache).json
         |> member "execution_publication_generation" |> to_int) > old_generation);
    check bool "old request success is refused" false
      (Surfaces.For_testing.publish_execution_attempt_success old_attempt
        (`Assoc ["marker", `String "retired-scope"]));
    check bool "old request failure cannot degrade the current answer" false
      (Surfaces.For_testing.publish_execution_attempt_failure old_attempt Exit);
    let delayed = Surfaces.execution_cache_for_scope ~state old_scope in
    Cache.mark_cached_surface_success delayed (`String "delayed old lookup");
    check bool "delayed old lookup cannot retire the current owner" true
      (Surfaces.execution_cache ~state == current_cache);
    check bool "current answer survives old scope writes" true
      (Yojson.Safe.Util.member "marker" (Cache.snapshot current_cache).json = `String "current-scope");
    Surfaces.publish_shell_cache_success ~state ~scope:old_scope ~light:false
      (`Assoc ["marker", `String "late retired shell"]);
    check bool "old shell completion cannot seed current namespace truth" true
      (Option.is_none (Surfaces.last_good_shell_for_scope ~state (Mcp_server.workspace_scope state))))
;;

let test_mission_dependency_matrix () =
  let affects = Refresh.affects Refresh.Mission in
  List.iter (fun input -> check bool "actual Mission input is admitted" true (affects input))
    [Input.Workspace_agent_signal {agent = "source-agent"};
     Input.Workspace_messages {request_id = "source-message"; mention_delivery = Masc_domain.Mention_passive};
     Input.Execution_invalidated; Input.Operator_judgment Operator_judgment.Command_namespace;
     Input.Tool_host_attention];
  List.iter (fun input -> check bool "unread or own output cannot wake Mission" false (affects input))
    [Input.Operator_judgment Operator_judgment.Intervene; Input.Board;
     Input.Dataset Workspace_dataset_event.Workspace_health;
     Input.Dataset (Workspace_dataset_event.Dashboard_observation {topic = `Health; scope = `Workspace});
     Input.Telemetry_sample]
;;

let with_execution_workspace f =
  with_workspace (fun env state ->
    let config = Mcp_server.workspace_config state in
    let inherited = Runtime.For_testing.snapshot () in
    Fun.protect ~finally:(fun () ->
      Dashboard_projection_cache.register_operator_snapshot_json
        {snapshot = Operator_control.snapshot_json};
      Runtime.For_testing.restore inherited)
      (fun () ->
        let path = Filename.concat config.base_path "execution-runtime.toml" in
        let oc = open_out path in
        Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
          output_string oc (String.concat "\n" [
            "version = 1"; "[runtime]"; "default = \"test_provider.test_model\"";
            "[providers.test_provider]"; "display-name = \"Isolated metadata fixture\"";
            "protocol = \"openai-compatible-http\""; "endpoint = \"http://127.0.0.1:1\"";
            "[models.test_model]"; "api-name = \"test-model\""; "max-context = 8192";
            "tools-support = true"; "streaming = true"; "[test_provider.test_model]";
            "max-concurrent = 1"; ""]));
        (match Runtime.init_default ~config_path:path with
         | Ok () -> () | Error error -> fail error);
        ignore (Workspace.init config ~agent_name:None);
        Dashboard_projection_cache.register_operator_snapshot_json
          {snapshot = Operator_control.snapshot_json};
        Masc_test_deps.with_process_env "MASC_DASHBOARD_FIXTURES_ENABLED" (Some "false") (fun () ->
          Masc_test_deps.with_process_env "MASC_DASHBOARD_FIXTURE" None (fun () -> f env state))))
;;

let subscribe_execution_frames ~state ~sw ~id consume =
  let scope = Mcp_server.workspace_scope state in
  Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path:scope.config.base_path)
    ~observer_instance_id:(Server_observer_scope.instance_id scope) ~id
    ~callback:(fun event ->
      match Yojson.Safe.Util.member "type" event.Sse.ext_payload with
      | `String "execution_snapshot" ->
          let payload = Yojson.Safe.Util.member "payload" event.ext_payload in
          if Yojson.Safe.Util.member "execution_invalidated" payload = `Bool false
          then consume `Execution payload
      | `String "project_snapshot" -> consume `Project
          (Yojson.Safe.Util.member "payload" event.ext_payload)
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _ -> ()) ();
  Eio.Switch.on_release sw (fun () -> Sse.unsubscribe_external id)
;;

let test_actual_execution_worker_waits_for_original_store_writes () =
  with_execution_workspace (fun env state ->
    let config = Mcp_server.workspace_config state in
    let clock = Eio_mock.Clock.make () in
    Eio_mock.Clock.set_time clock (Time_compat.now ());
    let frames = Eio.Stream.create 8 in
    Eio.Switch.run (fun sw ->
      subscribe_execution_frames ~state ~sw ~id:"execution-original-write" (fun kind payload ->
        match kind with `Execution -> Eio.Stream.add frames payload | `Project -> ());
      Surfaces.start_execution_refresh_loop ~state ~sw
        ~clock:(clock :> float Eio.Time.clock_ty Eio.Resource.t)
        ~net:(Eio.Stdenv.net env) ~mono_clock:(Eio.Stdenv.mono_clock env);
      let initial = Eio.Stream.take frames in
      check int "real empty workspace starts with no active agent" 0
        Yojson.Safe.Util.(initial |> member "agents" |> to_list |> List.length);
      Eio.Fiber.yield ();
      check bool "successful production worker has no cadence timer" false
        (Eio_mock.Clock.try_advance clock);
      let agent : Masc_domain.agent = {id = None; name = "original-agent";
        agent_type = "review"; status = Masc_domain.Active; capabilities = [];
        current_task = None; session_bound_at = "2020-01-01T00:00:00Z";
        last_seen = "2020-01-01T00:01:00Z"; meta = None} in
      let path = Filename.concat (Workspace.agents_dir config) "original-agent.json" in
      Workspace_agent_record.write config path ~previous:None agent;
      let refreshed = Eio.Stream.take frames in
      let rows = Yojson.Safe.Util.(refreshed |> member "agents" |> to_list) in
      check bool "canonical execution contains the actual committed agent" true
        (List.exists (fun row -> Yojson.Safe.Util.member "name" row = `String agent.name
          && Yojson.Safe.Util.member "last_seen" row = `String agent.last_seen) rows);
      Eio.Fiber.yield ();
      check bool "source and output settle without a feedback timer" false
        (Eio_mock.Clock.try_advance clock);
      let previous_task_hook = Atomic.get Workspace_hooks.on_task_mutation_fn in
      Fun.protect ~finally:(fun () ->
        Atomic.set Workspace_hooks.on_task_mutation_fn previous_task_hook)
        (fun () ->
          Surfaces.install_task_mutation_cache_invalidation
            ~invalidate_full_health_snapshot:(fun () -> ()) ();
          let task = match Workspace.add_task_with_result config
              ~title:"Original Todo source" ~priority:2 ~description:"Isolated store commit" with
            | Ok task -> task
            | Error error -> fail (Workspace.add_task_error_to_string error) in
          (* The actual mutation emits a timestamped execution_snapshot with
             its compact tombstone under payload. A flattened decoder-only
             fixture would not exercise this producer contract. *)
          let canonical = Eio.Stream.take frames in
          let tasks = Yojson.Safe.Util.(canonical |> member "tasks" |> to_list) in
          check bool "Todo commit reaches the production worker through its actual compact hint" true
            (List.exists (fun row -> Yojson.Safe.Util.member "id" row = `String task.task_id) tasks);
          Eio.Fiber.yield ();
          check bool "the Task update settles without a periodic scan" false
            (Eio_mock.Clock.try_advance clock)));
    check bool "normal release removes source worker waits" false (Eio_mock.Clock.try_advance clock))
;;

let test_late_lifecycle_patch_retains_the_source_read_debt () =
  with_execution_workspace (fun env state ->
    let config = Mcp_server.workspace_config state in
    let task = match Workspace.add_task_with_result config
        ~title:"Retained source observation" ~priority:2 ~description:"Original committed task" with
      | Ok task -> task
      | Error error -> fail (Workspace.add_task_error_to_string error) in
    let clock = Eio_mock.Clock.make () in
    Eio_mock.Clock.set_time clock (Time_compat.now ());
    let first, signal_first = Eio.Promise.create () in
    let release, release_first = Eio.Promise.create () in
    let calls = Atomic.make 0 in
    let frames = Eio.Stream.create 8 in
    Dashboard_projection_cache.register_operator_snapshot_json {snapshot =
      (fun ?read_policy ?actor ?view ?include_messages ?include_keepers
          ?include_summary_fields ?lightweight_summary ctx ->
        let call = Atomic.fetch_and_add calls 1 + 1 in
        let json = Operator_control.snapshot_json ?read_policy ?actor ?view
            ?include_messages ?include_keepers ?include_summary_fields ?lightweight_summary ctx in
        if call = 1 then (
          Eio.Promise.resolve signal_first ();
          Eio.Promise.await release);
        json)};
    Eio.Switch.run (fun sw ->
      subscribe_execution_frames ~state ~sw ~id:"execution-late-lifecycle-patch" (fun kind payload ->
        match kind with `Execution -> Eio.Stream.add frames payload | `Project -> ());
      Surfaces.start_execution_refresh_loop ~state ~sw
        ~clock:(clock :> float Eio.Time.clock_ty Eio.Resource.t)
        ~net:(Eio.Stdenv.net env) ~mono_clock:(Eio.Stdenv.mono_clock env);
      Eio.Promise.await first;
      let owner = Surfaces.For_testing.owner_for_state ~state in
      let before = Surfaces.For_testing.execution_publication_generation ~owner () in
      (* Model a listener arriving after the original phase hint was consumed.
         Drive its production patch boundary without adding
         another input that could hide its missing trailing read. A cold cache
         has no runtime row to patch, but still advances the attempt epoch. *)
      Surfaces.patch_keeper_dependent_caches ~keeper_name:"delayed-lifecycle"
        ~event:(Keeper_lifecycle_events.Phase_event Keeper_state_machine.Stopped);
      let current = Surfaces.For_testing.execution_publication_generation ~owner () in
      check bool "the actual lifecycle patch supersedes the held attempt" true (current > before);
      check bool "a cold lifecycle patch is not a completed source read" false
        (Cache.cached_surface_has_success (Surfaces.execution_cache ~state));
      Eio.Promise.resolve release_first ();
      let canonical = Eio.Stream.take frames in
      check int "the old attempt is refused and exactly one owed read follows" 2 (Atomic.get calls);
      check int "canonical output belongs to the patch's current attempt epoch" current
        Yojson.Safe.Util.(canonical |> member "execution_publication_generation" |> to_int);
      let tasks = Yojson.Safe.Util.(canonical |> member "tasks" |> to_list) in
      check bool "the trailing actual reader publishes the original committed Task" true
        (List.exists (fun row -> Yojson.Safe.Util.member "id" row = `String task.task_id) tasks);
      check bool "the trailing observation settles the cold cache" true
        (Cache.cached_surface_has_success (Surfaces.execution_cache ~state));
      Eio.Fiber.yield ();
      check bool "successful recovery leaves no healthy timer" false (Eio_mock.Clock.try_advance clock));
    check bool "release cancels the source owner waits" false (Eio_mock.Clock.try_advance clock))
;;

let test_http_wins_before_source_read_and_shell_completion_still_publishes ~force () =
  with_execution_workspace (fun env state ->
    (* Link the real namespace callback. These metadata projections do not
       invoke the fixture's loopback provider endpoint. *)
    ignore (Server_dashboard_http_namespace_truth.namespace_truth_snapshot_from_caches state);
    let first, signal_first = Eio.Promise.create () in
    let release, release_first = Eio.Promise.create () in
    let third, signal_third = Eio.Promise.create () in
    let calls = Atomic.make 0 in
    let executions = Eio.Stream.create 8 and projects = Eio.Stream.create 8 in
    Dashboard_projection_cache.register_operator_snapshot_json {snapshot =
      (fun ?read_policy ?actor ?view ?include_messages ?include_keepers
          ?include_summary_fields ?lightweight_summary ctx ->
        let call = Atomic.fetch_and_add calls 1 + 1 in
        if call = 1 then (
          Eio.Promise.resolve signal_first ();
          Eio.Promise.await release);
        if call = 3 then Eio.Promise.resolve signal_third ();
        Operator_control.snapshot_json ?read_policy ?actor ?view ?include_messages
          ?include_keepers ?include_summary_fields ?lightweight_summary ctx)};
    Eio.Switch.run (fun sw ->
      subscribe_execution_frames ~state ~sw ~id:"execution-request-completion" (fun kind payload ->
        match kind with
        | `Execution -> Eio.Stream.add executions payload
        | `Project -> Eio.Stream.add projects payload);
      Surfaces.start_execution_refresh_loop ~state ~sw ~clock:(Eio.Stdenv.clock env)
        ~net:(Eio.Stdenv.net env) ~mono_clock:(Eio.Stdenv.mono_clock env);
      Eio.Promise.await first;
      let request = Httpun.Request.create `GET
          (if force then "/api/v1/dashboard/execution?force=1" else "/api/v1/dashboard/execution") in
      let response = Surfaces.dashboard_execution_http_json ~state ~sw
          ~clock:(Eio.Stdenv.clock env) request in
      let expected_instance = Server_observer_scope.instance_id (Mcp_server.workspace_scope state) in
      check bool "actual request finished while the source read is held" true
        (Yojson.Safe.Util.(response |> member "query" |> member "force") = `Bool force);
      check string "HTTP body attests the originally admitted observer instance" expected_instance
        Yojson.Safe.Util.(response |> member "observer_instance_id" |> to_string);
      let frame = Eio.Stream.take executions in
      check string "canonical execution retains that exact instance" expected_instance
        Yojson.Safe.Util.(frame |> member "observer_instance_id" |> to_string);
      check bool "HTTP installation publishes the current owned answer" true
        (Yojson.Safe.Util.member "execution_publication_epoch" frame
         = Yojson.Safe.Util.member "execution_publication_epoch" (Cache.snapshot (Surfaces.execution_cache ~state)).json);
      let initial_project = Eio.Stream.take projects in
      check string "canonical namespace retains the same captured instance" expected_instance
        Yojson.Safe.Util.(initial_project |> member "observer_instance_id" |> to_string);
      let scope = Mcp_server.workspace_scope state in
      let shell count =
        `Assoc ["paths", `Assoc ["effective_base_path", `String scope.config.base_path];
          "status", `Assoc ["project", `String "ready"];
          "counts", `Assoc ["agents", `Int count; "tasks", `Int 0; "keepers", `Int 0;
            "total_runtimes", `Int 0]; "configured_keepers", `Int 0] in
      Surfaces.publish_shell_cache_success ~state ~scope ~light:false (shell 7);
      let project = Eio.Stream.take projects in
      check int "Shell installation separately completes canonical namespace truth" 7
        Yojson.Safe.Util.(project |> member "workspace" |> member "counts" |> member "agents" |> to_int);
      Surfaces.publish_shell_cache_success ~state ~scope ~light:true (`Assoc ["ready", `Bool true]);
      let unchanged = Eio.Stream.take projects in
      check int "light Shell completion remains visible when namespace values are equal" 7
        Yojson.Safe.Util.(unchanged |> member "workspace" |> member "counts" |> member "agents" |> to_int);
      let inherited_hook = Atomic.get Sse.buffer_commit_test_hook in
      let failed_once = Atomic.make false in
      Fun.protect ~finally:(fun () -> Atomic.set Sse.buffer_commit_test_hook inherited_hook) (fun () ->
        Atomic.set Sse.buffer_commit_test_hook (Some (fun () ->
          if Atomic.compare_and_set failed_once false true then
            raise (Failure "isolated completion replay failure")));
        Surfaces.publish_shell_cache_success ~state ~scope ~light:false (shell 8);
        let recovered = Eio.Stream.take projects in
        check bool "the production publisher crossed an actual replay failure" true (Atomic.get failed_once);
        check int "failed replay insertion retains canonical completion debt" 8
          Yojson.Safe.Util.(recovered |> member "workspace" |> member "counts" |> member "agents" |> to_int));
      Eio.Promise.resolve release_first ();
      Eio.Promise.await third;
      check int "request completion leaves one owed source follow-up" 3 (Atomic.get calls));
    check (option string) "normal cancellation cannot degrade the completed HTTP answer"
      None (Cache.snapshot (Surfaces.execution_cache ~state)).last_error)
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

let test_actual_mission_source_inputs_preserve_writer_outcomes () =
  with_workspace (fun _env state ->
    let config = Mcp_server.workspace_config state in
    let other_base = Filename.concat config.base_path "other-judgment-store" in
    let own = ref [] and other = ref [] in
    let confidence = match Operator_judgment.Confidence.of_float 0.91 with
      | Some confidence -> confidence | None -> fail "invalid fixture confidence" in
    let write config surface = Operator_judgment.record config ~surface
        ~target_type:Operator_judgment.Workspace ~target_id:None
        ~summary:"Isolated actual source commit" ~confidence
        ~generated_at:"1970-01-01T00:01:40Z" ~generated_at_unix:100.0
        ~fresh_until:"1970-01-01T00:01:50Z" ~fresh_until_unix:110.0
        ~keeper_name:"source-judge" () in
    Eio.Switch.run (fun sw ->
      Input.subscribe ~sw ~base_path:config.base_path (fun input -> own := input :: !own);
      Input.subscribe ~sw ~base_path:other_base (fun input -> other := input :: !other);
      let bad_judgment = Operator_judgment.subscribe_written (fun _ -> raise Exit) in
      let bad_log = Log.Ring.subscribe_published (fun change ->
        if String.equal change.entry.module_name Failure_envelope.tool_host_log_module_name then raise Exit) in
      Eio.Switch.on_release sw (fun () -> bad_judgment (); bad_log ());
      let failed_judgments = Operator_judgment.failed_write_notifications ()
      and failed_logs = Log.Ring.failed_publication_notifications () in
      let written = write config Operator_judgment.Command_namespace in
      check bool "actual judgment append reaches its original workspace" true
        (List.mem (Input.Operator_judgment Operator_judgment.Command_namespace) !own);
      check int "another workspace does not receive the judgment" 0 (List.length !other);
      check bool "listener failure cannot erase the exact stored judgment" true
        (List.exists (fun row -> String.equal row.Operator_judgment.judgment_id written.judgment_id)
          (Operator_judgment.load_all config));
      let own_count = List.length !own in
      ignore (write (Workspace.default_config other_base) Operator_judgment.Intervene);
      check int "a foreign append cannot wake the original workspace" own_count (List.length !own);
      check bool "the foreign append retains its own exact source surface" true
        (List.mem (Input.Operator_judgment Operator_judgment.Intervene) !other);
      let failed_config = Workspace.default_config (Filename.concat config.base_path "failed-judgment-store") in
      Fs_compat.mkdir_p (Filename.dirname (Operator_judgment.judgments_path failed_config));
      Fs_compat.mkdir_p (Operator_judgment.judgments_path failed_config);
      let failed_inputs = ref [] in
      Input.subscribe ~sw ~base_path:failed_config.base_path
        (fun input -> failed_inputs := input :: !failed_inputs);
      let append_error = try ignore (write failed_config Operator_judgment.Command_namespace); None with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Some exn in
      check bool "an actual pre-append read failure retains its original exception" true (Option.is_some append_error);
      check int "a read rejected before append creates no writer notification" 0 (List.length !failed_inputs);
      Log.legacy_stderr ~level:Log.Info ~module_name:"UnrelatedMissionLog" "unrelated source";
      check int "unrelated process logging does not feed back to Mission" own_count (List.length !own);
      Log.legacy_stderr ~level:Log.Error
        ~module_name:Failure_envelope.tool_host_log_module_name "original process selection source";
      check bool "ToolHost ring selection is an actual process input" true
        (List.mem Input.Tool_host_attention !own && List.mem Input.Tool_host_attention !other);
      check int "judgment observer failures are counted without changing either append"
        (failed_judgments + 2) (Operator_judgment.failed_write_notifications ());
      check int "ring observer failure is counted without changing the log operation"
        (failed_logs + 1) (Log.Ring.failed_publication_notifications ()));
    let count = List.length !own in
    ignore (write config Operator_judgment.Command_namespace);
    Log.legacy_stderr ~level:Log.Error
      ~module_name:Failure_envelope.tool_host_log_module_name "after subscriber release";
    check int "normal release removes both actual source subscriptions" count (List.length !own))
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
                  test_case "closed source dependencies" `Quick test_exact_dependency_matrix;
                  test_case "execution original dependencies" `Quick test_execution_dependency_matrix]
    ; "mission policy", [test_case "closed Mission source dependencies" `Quick test_mission_dependency_matrix]
    ; "consumer", [test_case "actual trust cache completion and scope cell" `Quick test_actual_cache_completion_and_scope_cell;
                    test_case "replacement cancels the retired read" `Quick test_replaced_read_is_cancelled_before_new_generation;
                    test_case "actual commits preserve writer outcomes" `Quick test_actual_commit_inputs_and_listener_failure;
                    test_case "actual Mission inputs preserve original writer outcomes" `Quick test_actual_mission_source_inputs_preserve_writer_outcomes;
                    test_case "async tool commit preserves its workspace owner" `Quick test_async_tool_commit_keeps_its_store_owner;
                    test_case "retired execution request cannot replace current scope" `Quick test_execution_owner_rejects_a_retired_request;
                    test_case "actual execution worker follows original store writes" `Quick test_actual_execution_worker_waits_for_original_store_writes;
                    test_case "late lifecycle patch retains the owed source read" `Quick test_late_lifecycle_patch_retains_the_source_read_debt;
                    test_case "cold HTTP first and Shell complete canonical truth" `Quick
                      (test_http_wins_before_source_read_and_shell_completion_still_publishes ~force:false);
                    test_case "force HTTP first and Shell complete canonical truth" `Quick
                      (test_http_wins_before_source_read_and_shell_completion_still_publishes ~force:true)] ]
;;
