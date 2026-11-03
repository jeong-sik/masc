open Alcotest

module Expiry = Server_pending_confirm_expiry
module Store = Operator_pending_confirm
module Observation = Masc.Pending_confirm_observation
module Server_keeper_waiting_inventory = Masc.Server_keeper_waiting_inventory

let fixture ~token ~expires_at : Store.pending_confirm =
  { confirm_token = token
  ; trace_id = "trace-" ^ token
  ; actor = "operator"
  ; action_type = "broadcast"
  ; target_type = "workspace"
  ; target_id = None
  ; payload = `Assoc [ "message", `String "fixture" ]
  ; delegated_tool = "masc_broadcast"
  ; created_at = "1970-01-01T00:00:00Z"
  ; expires_at
  }

let with_workspace f =
  let base_path = Masc_test_deps.setup_test_workspace () in
  let previous_fs = Fs_compat.get_fs_opt () in
  Fun.protect ~finally:(fun () ->
    Store.install_change_observer (fun ~base_path:_ -> ());
    (match previous_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ());
    Masc_test_deps.cleanup_test_workspace base_path)
    (fun () -> Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let state = Masc.Mcp_server.For_testing.create_state ~base_path in
      let config = Masc.Mcp_server.workspace_config state in
      ignore (Workspace_core.init config ~agent_name:(Some "test"));
      Fs_compat.mkdir_p (Store.operator_dir config);
      f env state config))

let future_time clock offset =
  let text = Masc_domain.iso8601_of_unix_seconds (Eio.Time.now clock +. offset) in
  let at = Option.get (Masc_domain.parse_iso8601_opt text) in
  text, at

let wait_for clock condition =
  Eio.Time.with_timeout_exn clock 3.0 (fun () ->
    while not (condition ()) do Eio.Time.sleep clock 0.005 done)

let test_deadline_and_idle () =
  with_workspace (fun env state _config ->
    let clock = Eio.Stdenv.clock env in
    let text, at = future_time clock 2.5 in
    let reads = ref 0 and invalidations = ref 0 in
    Eio.Switch.run (fun sw ->
      Expiry.For_testing.start ~sw ~clock ~state
        ~read:(fun _ -> incr reads; Ok [fixture ~token:"first" ~expires_at:(Some text)])
        ~invalidate:(fun ~base_path:_ -> incr invalidations);
      wait_for clock (fun () -> !reads >= 1);
      check int "one startup read" 1 !reads;
      Eio.Time.sleep clock 0.2;
      check int "idle does not rescan" 1 !reads;
      Eio.Time.sleep_until clock (at +. 0.25);
      wait_for clock (fun () -> !invalidations >= 1 && !reads >= 2);
      check int "deadline invalidates health" 1 !invalidations;
      check int "deadline observes store once" 2 !reads;
      Eio.Time.sleep clock 0.2;
      check int "an uncleared expired row does not spin" 2 !reads;
      check int "expiry is not published twice" 1 !invalidations))

let test_change_rearms_and_foreign_does_not_wake () =
  with_workspace (fun env state config ->
    let clock = Eio.Stdenv.clock env in
    let late, _ = future_time clock 20.0 in
    let early, at = future_time clock 2.5 in
    let entries = ref [fixture ~token:"late" ~expires_at:(Some late)] in
    let reads = ref 0 and invalidations = ref 0 in
    let other = Filename.concat config.Masc.Workspace.base_path "other" in
    let alias = Filename.concat config.base_path "." in
    Unix.mkdir other 0o755;
    let other_config = Workspace_core.default_config other in
    let alias_config = Workspace_core.default_config alias in
    ignore (Workspace_core.init other_config ~agent_name:(Some "test"));
    Fs_compat.mkdir_p (Store.operator_dir other_config);
    Eio.Switch.run (fun sw ->
      Expiry.For_testing.start ~sw ~clock ~state
        ~read:(fun _ -> incr reads; Ok !entries)
        ~invalidate:(fun ~base_path ->
          if Unix.realpath base_path = Unix.realpath config.base_path then incr invalidations);
      wait_for clock (fun () -> !reads >= 1);
      check int "initial observation" 1 !reads;
      Store.write_pending_confirms other_config [] |> Result.get_ok;
      Eio.Time.sleep clock 0.05;
      check int "foreign publication does not rescan" 1 !reads;
      Store.write_pending_confirms alias_config [] |> Result.get_ok;
      wait_for clock (fun () -> !reads >= 2);
      check int "a normalized path wakes the same workspace" 2 !reads;
      entries := [fixture ~token:"early" ~expires_at:(Some early)];
      Store.write_pending_confirms config [] |> Result.get_ok;
      wait_for clock (fun () -> !reads >= 3);
      check int "current publication reschedules" 3 !reads;
      check int "both matching publications invalidate" 2 !invalidations;
      Eio.Time.sleep_until clock (at +. 0.25);
      wait_for clock (fun () -> !invalidations >= 3 && !reads >= 4);
      check int "earlier deadline invalidates" 3 !invalidations;
      check int "earlier deadline read" 4 !reads))

let test_replaced_workspace_discards_old_read () =
  with_workspace (fun env state _config ->
    let clock = Eio.Stdenv.clock env in
    let started, publish_started = Eio.Promise.create () in
    let release, publish_release = Eio.Promise.create () in
    let successor, publish_successor = Eio.Promise.create () in
    let reads = ref 0 and invalidations = ref 0 in
    Eio.Switch.run (fun sw ->
      Expiry.For_testing.start ~sw ~clock ~state
        ~read:(fun _ ->
          incr reads;
          if !reads = 1 then begin
            Eio.Promise.resolve publish_started ();
            Eio.Promise.await release;
            Ok [fixture ~token:"old" ~expires_at:(Some "2026-01-02T00:00:00Z")]
          end else begin
            Eio.Promise.resolve publish_successor ();
            Ok []
          end)
        ~invalidate:(fun ~base_path:_ -> incr invalidations);
      Eio.Promise.await started;
      let old = Masc.Mcp_server.workspace_scope state in
      Masc.Mcp_server.set_workspace_config state old.config |> Result.get_ok;
      Eio.Time.with_timeout_exn clock 2.0 (fun () -> Eio.Promise.await successor);
      Eio.Promise.resolve publish_release ();
      check int "successor is observed" 2 !reads;
      check int "retired read cannot invalidate successor" 0 !invalidations))

let test_failed_read_waits_for_publication () =
  with_workspace (fun env state config ->
    let clock = Eio.Stdenv.clock env in
    let reads = ref 0 and invalidations = ref 0 and failed = ref true in
    Eio.Switch.run (fun sw ->
      Expiry.For_testing.start ~sw ~clock ~state
        ~read:(fun _ ->
          incr reads;
          if !failed then Error "confirm-token-test-only-do-not-log" else Ok [])
        ~invalidate:(fun ~base_path:_ -> incr invalidations);
      wait_for clock (fun () -> !invalidations >= 1);
      Eio.Time.sleep clock 0.2;
      check int "a failed source does not spin" 1 !reads;
      check int "a failed source invalidates health" 1 !invalidations;
      failed := false;
      Store.write_pending_confirms config [] |> Result.get_ok;
      wait_for clock (fun () -> !invalidations >= 3);
      check int "publication retries observation" 2 !reads;
      check int "publication and recovery invalidate health" 3 !invalidations))

let test_unavailable_wall_timer_waits_for_publication () =
  with_workspace (fun env state config ->
    let clock = Eio.Stdenv.clock env in
    let text, _ = future_time clock 20.0 in
    let entries = ref [fixture ~token:"timer" ~expires_at:(Some text)] in
    let reads = ref 0 and waits = ref 0 and invalidations = ref 0 in
    Eio.Switch.run (fun sw ->
      Expiry.For_testing.start_with_sleep ~sw ~clock ~state
        ~sleep_until:(fun _ -> incr waits; failwith "timer source unavailable")
        ~read:(fun _ -> incr reads; Ok !entries)
        ~invalidate:(fun ~base_path:_ -> incr invalidations);
      wait_for clock (fun () -> !invalidations >= 1);
      Eio.Time.sleep clock 0.2;
      check int "failed timer waits before retrying" 1 !waits;
      check int "failed timer does not trigger repeated reads" 1 !reads;
      entries := [];
      Store.write_pending_confirms config [] |> Result.get_ok;
      wait_for clock (fun () -> !reads >= 2);
      check int "a later publication resumes observation" 2 !reads))
;;

let test_failed_read_recovers_without_publication () =
  with_workspace (fun env state _config ->
    let clock = Eio.Stdenv.clock env in
    let reads = ref 0 and invalidations = ref 0 in
    Eio.Switch.run (fun sw ->
      Expiry.For_testing.start ~sw ~clock ~state
        ~read:(fun _ ->
          incr reads;
          if !reads = 1 then Error "injected read failure" else Ok [])
        ~invalidate:(fun ~base_path:_ -> incr invalidations);
      wait_for clock (fun () -> !reads >= 2 && !invalidations >= 2);
      check int "the failed source is retried without a store write" 2 !reads;
      check int "failure and recovery both invalidate" 2 !invalidations;
      Eio.Time.sleep clock 0.2;
      check int "a recovered idle source is not scanned again" 2 !reads))
;;

let test_unavailable_wall_timer_recovers_without_publication () =
  with_workspace (fun env state _config ->
    let clock = Eio.Stdenv.clock env in
    let text, at = future_time clock 20.0 in
    let reads = ref 0 and waits = ref 0 and invalidations = ref 0 in
    Eio.Switch.run (fun sw ->
      Expiry.For_testing.start_with_sleep ~sw ~clock ~state
        ~sleep_until:(fun deadline ->
          incr waits;
          if !waits = 1 then failwith "injected timer failure";
          Eio.Time.sleep_until clock deadline)
        ~read:(fun _ -> incr reads; Ok [fixture ~token:"timer" ~expires_at:(Some text)])
        ~invalidate:(fun ~base_path:_ -> incr invalidations);
      wait_for clock (fun () -> !waits >= 2);
      check int "the unavailable timer is retried without a store write" 2 !waits;
      check int "timer installation retries do not reread the store" 1 !reads;
      check int "the timer failure invalidates once" 1 !invalidations;
      check bool "the deadline is still in the future" true (Eio.Time.now clock < at);
      Eio.Time.sleep clock 0.2;
      check int "an armed timer is not retried" 2 !waits))
;;

let test_replaced_workspace_cancels_retry () =
  with_workspace (fun env state _config ->
    let clock = Eio.Stdenv.clock env in
    let reads = ref 0 and invalidations = ref 0 in
    Eio.Switch.run (fun sw ->
      Expiry.For_testing.start ~sw ~clock ~state
        ~read:(fun _ ->
          incr reads;
          if !reads = 1 then Error "injected read failure" else Ok [])
        ~invalidate:(fun ~base_path:_ -> incr invalidations);
      wait_for clock (fun () -> !invalidations = 1);
      let old = Masc.Mcp_server.workspace_scope state in
      Masc.Mcp_server.set_workspace_config state old.config |> Result.get_ok;
      Eio.Time.with_timeout_exn clock 0.5 (fun () ->
        while !reads < 2 do Eio.Time.sleep clock 0.005 done);
      Eio.Time.sleep clock 1.2;
      check int "retired scope's retry cannot scan the successor" 2 !reads;
      check int "the successor does not inherit the old failure" 1 !invalidations))
;;

let test_timer_failure_still_notifies_expiry () =
  with_workspace (fun env state _config ->
    let clock = Eio.Stdenv.clock env in
    let text, at = future_time clock 2.5 in
    let reads = ref 0 and waits = ref 0 and invalidations = ref 0 in
    Eio.Switch.run (fun sw ->
      Expiry.For_testing.start_with_sleep ~sw ~clock ~state
        ~sleep_until:(fun deadline ->
          incr waits;
          if !waits = 1 then failwith "injected timer failure";
          Wall_deadline.sleep_until deadline)
        ~read:(fun _ -> incr reads; Ok [fixture ~token:"timer" ~expires_at:(Some text)])
        ~invalidate:(fun ~base_path:_ -> incr invalidations);
      wait_for clock (fun () -> !reads >= 2 && !invalidations >= 2);
      check bool "the expiry is not published early" true (Eio.Time.now clock >= at);
      check int "failure and expiry each invalidate once" 2 !invalidations;
      check int "expiry rereads the store once" 2 !reads;
      Eio.Time.sleep clock 0.2;
      check int "an uncleared expiry does not cause another read" 2 !reads;
      check int "an uncleared expiry does not cause another invalidation" 2 !invalidations))
;;

let test_expired_at_start_wakes_once () =
  with_workspace (fun env state config ->
    let clock = Eio.Stdenv.clock env in
    let expired, _ = future_time clock (-. 2.0) in
    Store.write_pending_confirms config
      [fixture ~token:"old" ~expires_at:(Some expired)]
    |> Result.get_ok;
    let reads = ref 0 and invalidations = ref 0 in
    Eio.Switch.run (fun sw ->
      Expiry.For_testing.start ~sw ~clock ~state
        ~read:(fun config -> incr reads; Ok (Store.raw_pending_confirms config))
        ~invalidate:(fun ~base_path:_ -> incr invalidations);
      wait_for clock (fun () -> !invalidations >= 1);
      Eio.Time.sleep clock 0.2;
      check int "stored expired entry wakes once on startup" 1 !invalidations;
      check int "stored expired entry does not spin" 1 !reads))

let test_publication_during_read_rearms_deadline () =
  with_workspace (fun env state config ->
    let clock = Eio.Stdenv.clock env in
    let late, _ = future_time clock 20.0 in
    let early, at = future_time clock 2.5 in
    Store.write_pending_confirms config [fixture ~token:"late" ~expires_at:(Some late)]
    |> Result.get_ok;
    let started, publish_started = Eio.Promise.create () in
    let release, publish_release = Eio.Promise.create () in
    let reads = ref 0 and invalidations = ref 0 in
    Eio.Switch.run (fun sw ->
      Expiry.For_testing.start ~sw ~clock ~state
        ~read:(fun config ->
          incr reads;
          let observed = Store.raw_pending_confirms config in
          if !reads = 1 then begin
            Eio.Promise.resolve publish_started ();
            Eio.Promise.await release
          end;
          Ok observed)
        ~invalidate:(fun ~base_path:_ -> incr invalidations);
      Eio.Promise.await started;
      Store.write_pending_confirms config [fixture ~token:"early" ~expires_at:(Some early)]
      |> Result.get_ok;
      Eio.Promise.resolve publish_release ();
      wait_for clock (fun () -> !reads >= 2);
      check int "publication is observed after the in-flight read" 2 !reads;
      Eio.Time.sleep_until clock (at +. 0.25);
      wait_for clock (fun () -> !invalidations >= 2);
      check int "the new deadline wakes health" 2 !invalidations))

let test_non_eio_failed_attempt_wakes_worker () =
  with_workspace (fun env state config ->
    let clock = Eio.Stdenv.clock env in
    let text, _ = future_time clock 20.0 in
    let reads = ref 0 and invalidations = Atomic.make 0 in
    Eio.Switch.run (fun sw ->
      Expiry.For_testing.start ~sw ~clock ~state
        ~read:(fun config -> incr reads; Ok (Store.raw_pending_confirms config))
        ~invalidate:(fun ~base_path:_ -> ignore (Atomic.fetch_and_add invalidations 1));
      wait_for clock (fun () -> !reads >= 1);
      let outside_eio, rejected =
        Eio.Domain_manager.run_raw (Eio.Stdenv.domain_mgr env) (fun () ->
          let outside_eio = Fs_compat.execution_context () = Non_eio in
          let rejected =
            match Store.write_pending_confirms config
              [fixture ~token:"domain" ~expires_at:(Some text)] with
            | _ -> false
            | exception Effect.Unhandled _ -> true in
          outside_eio, rejected) in
      check bool "attempt was outside Eio" true outside_eio;
      check bool "the Eio-only backend rejected the attempt" true rejected;
      wait_for clock (fun () -> !reads >= 2);
      check int "failed attempt invalidates once" 1 (Atomic.get invalidations);
      check int "failed attempt wakes the worker" 2 !reads;
      check int "the rejected write did not commit" 0
        (List.length (Store.raw_pending_confirms config))))

let test_persisted_deadline_wakes_full_health () =
  with_workspace (fun env state config ->
    let clock = Eio.Stdenv.clock env in
    let previous_state = Server_auth.For_testing.snapshot_server_state () in
    let module Runtime = Server_routes_http_runtime in
    Fun.protect ~finally:(fun () ->
      Server_auth.For_testing.restore_server_state previous_state;
      Runtime.For_testing.reset_full_health_snapshot ();
      ignore (Runtime.For_testing.take_full_health_wakeup_nonblocking ()))
      (fun () ->
        Server_auth.For_testing.restore_server_state (Some state);
        let text, at = future_time clock 2.5 in
        Store.write_pending_confirms config [fixture ~token:"stored" ~expires_at:(Some text)]
        |> Result.get_ok;
        Runtime.For_testing.reset_full_health_snapshot ();
        ignore (Runtime.For_testing.take_full_health_wakeup_nonblocking ());
        Eio.Switch.run (fun sw ->
          let pool = Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
          Domain_pool_ref.set pool;
          Eio.Switch.on_release sw Domain_pool_ref.clear_for_tests;
          Expiry.start ~sw ~clock ~mono_clock:(Eio.Stdenv.mono_clock env) ~state;
          wait_for clock (fun () ->
            Observation.get config
            = Observation.Observed);
          check bool "the initial observed state wakes health" true
            (Runtime.For_testing.take_full_health_wakeup_nonblocking ());
          Eio.Time.sleep_until clock (at +. 0.25);
          Eio.Time.with_timeout_exn clock 3.0 (fun () ->
            Runtime.For_testing.take_full_health_wakeup ());
          check int "store cleanup drops the expired entry" 0
            (List.length (Store.read_pending_confirms_result config |> Result.get_ok)))))

let test_store_and_deadline_publish_scoped_sse () =
  with_workspace (fun env state config ->
    let clock = Eio.Stdenv.clock env in
    let base_path = config.Masc.Workspace.base_path in
    let other_path = Filename.concat base_path "foreign-confirm-workspace" in
    let current_session = "pending-confirm-invalidation-current" in
    let other_session = "pending-confirm-invalidation-other" in
    let external_id = "pending-confirm-invalidation-external" in
    let previous_state = Server_auth.For_testing.snapshot_server_state () in
    let module Runtime = Server_routes_http_runtime in
    Fun.protect ~finally:(fun () ->
      Masc.Sse.unsubscribe_external external_id;
      Masc.Sse.unregister current_session;
      Masc.Sse.unregister other_session;
      ignore (Masc.Session.McpSessionStore.remove current_session);
      ignore (Masc.Session.McpSessionStore.remove other_session);
      Server_auth.For_testing.restore_server_state previous_state;
      Runtime.For_testing.reset_full_health_snapshot ();
      ignore (Runtime.For_testing.take_full_health_wakeup_nonblocking ()))
      (fun () ->
        Unix.mkdir other_path 0o755;
        let other = Workspace_core.default_config other_path in
        ignore (Workspace_core.init other ~agent_name:(Some "test"));
        Fs_compat.mkdir_p (Store.operator_dir other);
        Server_auth.For_testing.restore_server_state (Some state);
        let register path session_id =
          let auth = Masc_test_deps.make_sse_auth path "pending-confirm-test" in
          ignore (Masc.Session.McpSessionStore.get_or_create ~id:session_id ());
          match Masc.Sse.register ~kind:Observer ~auth session_id ~last_event_id:0 with
          | Ok (_, stream, _) -> stream
          | Error error -> fail (Masc.Sse.registration_error_to_string error) in
        let current_stream = register base_path current_session in
        let other_stream = register other_path other_session in
        let authority = Masc.Sse.runtime_authority_exn ~base_path in
        let external_calls = ref 0 in
        Masc.Sse.subscribe_external ~runtime_authority:authority ~id:external_id
          ~callback:(fun _ -> incr external_calls) ();
        let receive stream =
          Eio.Time.with_timeout_exn clock 5.0 (fun () -> Masc.Sse.take_delivery stream) in
        Eio.Switch.run (fun sw ->
          let pool = Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
          Domain_pool_ref.set pool;
          Eio.Switch.on_release sw Domain_pool_ref.clear_for_tests;
          Expiry.start ~sw ~clock ~mono_clock:(Eio.Stdenv.mono_clock env) ~state;
          wait_for clock (fun () ->
            Observation.get config
            = Observation.Observed);
          let initial = receive current_stream in
          check bool "initial observation is announced" true
            (initial.payload = Masc.Pending_confirm_invalidation_event.json);
          let before_id = Masc.Sse.current_id () in
          Store.write_pending_confirms other [] |> Result.get_ok;
          let foreign = receive other_stream in
          check bool "foreign store event is scoped" true
            (foreign.payload = Masc.Pending_confirm_invalidation_event.json);
          check bool "foreign write does not reach current observer" true
            (Option.is_none (Masc.Sse.take_delivery_nonblocking current_stream));
          let text, at = future_time clock 3.5 in
          Store.write_pending_confirms config
            [fixture ~token:"not-for-sse" ~expires_at:(Some text)] |> Result.get_ok;
          let written = receive current_stream in
          check bool "write emits only the invalidation" true
            (written.payload = Masc.Pending_confirm_invalidation_event.json);
          wait_for clock (fun () ->
            Observation.get config
            = Observation.Observed);
          check bool "current write does not reach foreign observer" true
            (Option.is_none (Masc.Sse.take_delivery_nonblocking other_stream));
          Eio.Time.sleep clock 0.15;
          let rec drain_ready_announcements () =
            match Masc.Sse.take_delivery_nonblocking current_stream with
            | None -> ()
            | Some event ->
                check bool "observation announces only invalidation" true
                  (event.payload = Masc.Pending_confirm_invalidation_event.json);
                drain_ready_announcements () in
          drain_ready_announcements ();
          Eio.Time.sleep_until clock (at +. 0.15);
          let expired = receive current_stream in
          check bool "deadline emits only the invalidation" true
            (expired.payload = Masc.Pending_confirm_invalidation_event.json);
          wait_for clock (fun () -> Observation.get config = Observation.Observed);
          Eio.Time.sleep clock 0.15;
          drain_ready_announcements ();
          Eio.Time.sleep clock 0.15;
          check bool "uncleared expiry does not emit twice" true
            (Option.is_none (Masc.Sse.take_delivery_nonblocking current_stream));
          check int "no external subscriber callback" 0 !external_calls;
          let replay = Masc.Sse.replay_after_for_session ~runtime_authority:authority
            ~session_id:current_session ~kind:Observer before_id in
          check bool "write and deadline are replayed only for this workspace" true
            (List.exists (fun event -> event.Masc.Sse.event_id = written.event_id) replay.deliveries
             && List.exists (fun event -> event.Masc.Sse.event_id = expired.event_id) replay.deliveries
             && List.for_all (fun event -> event.Masc.Sse.payload = Masc.Pending_confirm_invalidation_event.json)
                  replay.deliveries));
        Store.write_pending_confirms config [] |> Result.get_ok;
        check bool "stopped worker does not enqueue to its old stream" true
          (Option.is_none (Masc.Sse.take_delivery_nonblocking current_stream))))

let test_shutdown_preserves_successor_observer () =
  with_workspace (fun env state config ->
    let clock = Eio.Stdenv.clock env in
    let successor_calls = ref 0 in
    Eio.Switch.run (fun sw ->
      Expiry.For_testing.start ~sw ~clock ~state ~read:(fun _ -> Ok [])
        ~invalidate:(fun ~base_path:_ -> ());
      Store.install_change_observer (fun ~base_path:_ -> incr successor_calls));
    Store.write_pending_confirms config [] |> Result.get_ok;
    check int "stopping an older worker preserves its successor" 1 !successor_calls)

let observation config =
  Observation.get config

let test_observation_revision_tracks_provider_replacement () =
  with_workspace (fun _env _state config ->
    let status = ref Observation.Initializing in
    let first _ = Observation.managed ~epoch:"test-scope" ~generation:1 !status in
    let second _ = Observation.managed ~epoch:"test-scope" ~generation:1 Observation.Observed in
    let previous = Observation.install first in
    Fun.protect
      ~finally:(fun () -> ignore (Observation.restore_if_current ~current:first ~previous))
      (fun () ->
        let before = Observation.read config in
        status := Observation.Observed;
        let after_status = Observation.read config in
        check bool "arming does not change the source revision" true
          (Observation.same_revision before after_status);
        let (_previous_first : Observation.provider) = Observation.install second in
        let (_previous_second : Observation.provider) = Observation.install first in
        let after_replacement = Observation.read config in
        check bool "reinstalling the same provider still changes its revision" false
          (Observation.same_revision before after_replacement)))

let test_deadline_observation_failure_and_recovery () =
  with_workspace (fun env state config ->
    let clock = Eio.Stdenv.clock env in
    let text, _ = future_time clock 20.0 in
    let reads = ref 0 and attempts = ref 0 and changes = ref [] in
    let read_release, publish_read_release = Eio.Promise.create () in
    let retry_release, publish_retry_release = Eio.Promise.create () in
    let previous_reader =
      Atomic.exchange Workspace_hooks.operator_pending_confirm_read_result_fn (fun _ -> Ok []) in
    Fun.protect
      ~finally:(fun () -> Atomic.set Workspace_hooks.operator_pending_confirm_read_result_fn previous_reader)
      (fun () ->
        Eio.Switch.run (fun sw ->
          Expiry.For_testing.start_with_observation ~sw ~clock ~state
            ~sleep_retry:(fun _ -> Eio.Promise.await retry_release)
            ~sleep_until:(fun ~on_armed at ->
              incr attempts;
              if !attempts = 1 then failwith "timer unavailable";
              on_armed ();
              Eio.Time.sleep_until clock at)
            ~read:(fun _ ->
              incr reads;
              Eio.Promise.await read_release;
              Ok [fixture ~token:"health" ~expires_at:(Some text)])
            ~invalidate:(fun ~base_path:_ -> ())
            ~observation_changed:(fun ~base_path:_ -> changes := observation config :: !changes);
          check bool "starting is not reported as observed" true
            (observation config = Observation.Initializing);
          Eio.Promise.resolve publish_read_release ();
          wait_for clock (fun () -> observation config = Observation.Deadline_unavailable);
          let health = Server_keeper_waiting_inventory.health_json config in
          check string "health is unavailable" "unavailable"
            Yojson.Safe.Util.(health |> member "status" |> to_string);
          check int "timer observation has a distinct error count" 1
            Yojson.Safe.Util.(health |> member "observation_error_count" |> to_int);
          let rows =
            Yojson.Safe.Util.(Server_keeper_waiting_inventory.dashboard_json config
              |> member "global_waiting_on" |> to_list) in
          check bool "waiting inventory identifies the unavailable observer" true
            (List.exists (fun row ->
              Yojson.Safe.Util.(row |> member "source" |> to_string) = "observation_unavailable"
              && Yojson.Safe.Util.(row |> member "detail" |> member "kind" |> to_string)
                 = "deadline_unavailable") rows);
          Eio.Promise.resolve publish_retry_release ();
          wait_for clock (fun () -> observation config = Observation.Observed);
          check int "timer recovery does not reread the store" 1 !reads;
          check bool "failure and recovery both notify observers" true
            (List.mem Observation.Deadline_unavailable !changes
             && List.mem Observation.Observed !changes));
        check bool "the stopped worker withdraws its observation" true
          (observation config = Observation.Not_managed)))

let test_read_observation_failure_and_recovery () =
  with_workspace (fun env state config ->
    let clock = Eio.Stdenv.clock env in
    let reads = ref 0 and changes = ref [] in
    let retry_release, publish_retry_release = Eio.Promise.create () in
    Eio.Switch.run (fun sw ->
      Expiry.For_testing.start_with_observation ~sw ~clock ~state
        ~sleep_retry:(fun _ -> Eio.Promise.await retry_release)
        ~sleep_until:(fun ~on_armed:_ _ -> failwith "no deadline expected")
        ~read:(fun _ ->
          incr reads;
          if !reads = 1 then Error "private injected source error" else Ok [])
        ~invalidate:(fun ~base_path:_ -> ())
        ~observation_changed:(fun ~base_path:_ -> changes := observation config :: !changes);
      wait_for clock (fun () -> observation config = Observation.Source_unavailable);
      Eio.Promise.resolve publish_retry_release ();
      wait_for clock (fun () -> observation config = Observation.Observed);
      check int "source recovery performs one retry" 2 !reads;
      check bool "read failure and recovery are both announced" true
        (List.mem Observation.Source_unavailable !changes
         && List.mem Observation.Observed !changes);
      Eio.Time.sleep clock 0.1;
      check int "healthy idle observation does not rescan" 2 !reads))

let test_elapsed_deadline_withdraws_observation_until_next_read () =
  with_workspace (fun env state config ->
    let clock = Eio.Stdenv.clock env in
    let text, _ = future_time clock 20.0 in
    let deadline, fire_deadline = Eio.Promise.create () in
    let reading, publish_reading = Eio.Promise.create () in
    let release, publish_release = Eio.Promise.create () in
    let reads = ref 0 and changes = ref [] in
    Eio.Switch.run (fun sw ->
      Expiry.For_testing.start_with_observation ~sw ~clock ~state
        ~sleep_retry:(Eio.Time.sleep clock)
        ~sleep_until:(fun ~on_armed _ -> on_armed (); Eio.Promise.await deadline)
        ~read:(fun _ ->
          incr reads;
          if !reads = 1 then Ok [fixture ~token:"elapsed" ~expires_at:(Some text)]
          else begin
            Eio.Promise.resolve publish_reading ();
            Eio.Promise.await release;
            Ok []
          end)
        ~invalidate:(fun ~base_path:_ -> ())
        ~observation_changed:(fun ~base_path:_ -> changes := observation config :: !changes);
      wait_for clock (fun () -> observation config = Observation.Observed);
      Eio.Promise.resolve fire_deadline ();
      Eio.Time.with_timeout_exn clock 2.0 (fun () -> Eio.Promise.await reading);
      check bool "an elapsed timer is not reported as armed" true
        (observation config = Observation.Initializing);
      let health = Server_keeper_waiting_inventory.health_json config in
      check string "health is unavailable while the next read waits" "unavailable"
        Yojson.Safe.Util.(health |> member "status" |> to_string);
      check int "the elapsed deadline makes observation incomplete" 1
        Yojson.Safe.Util.(health |> member "observation_error_count" |> to_int);
      Eio.Promise.resolve publish_release ();
      wait_for clock (fun () -> observation config = Observation.Observed);
      check bool "withdrawal and recovery are announced" true
        (List.mem Observation.Initializing !changes
         && List.mem Observation.Observed !changes)))

let test_observation_expires_before_the_timer_fiber_runs () =
  with_workspace (fun env state config ->
    let clock = Eio.Stdenv.clock env in
    let text, at = future_time clock 2.5 in
    let timer, _ = Eio.Promise.create () in
    Eio.Switch.run (fun sw ->
      Expiry.For_testing.start_with_observation ~sw ~clock ~state
        ~sleep_retry:(Eio.Time.sleep clock)
        ~sleep_until:(fun ~on_armed _ -> on_armed (); Eio.Promise.await timer)
        ~read:(fun _ -> Ok [fixture ~token:"deadline" ~expires_at:(Some text)])
        ~invalidate:(fun ~base_path:_ -> ())
        ~observation_changed:(fun ~base_path:_ -> ());
      wait_for clock (fun () -> observation config = Observation.Observed);
      Eio.Time.sleep_until clock (at +. 0.05);
      check bool "a past deadline is not reported as observed" true
        (observation config = Observation.Initializing);
      let health = Server_keeper_waiting_inventory.health_json config in
      check string "health is unavailable before the timer fiber resumes" "unavailable"
        Yojson.Safe.Util.(health |> member "status" |> to_string);
      check int "the passed deadline makes observation incomplete" 1
        Yojson.Safe.Util.(health |> member "observation_error_count" |> to_int)))

let test_observation_does_not_cross_workspace_epoch () =
  with_workspace (fun env state config ->
    let clock = Eio.Stdenv.clock env in
    let started, publish_started = Eio.Promise.create () in
    let release, publish_release = Eio.Promise.create () in
    let reads = ref 0 in
    let other = Filename.concat config.Masc.Workspace.base_path "other-observation" in
    Unix.mkdir other 0o755;
    let other_config = Workspace_core.default_config other in
    ignore (Workspace_core.init other_config ~agent_name:(Some "test"));
    Eio.Switch.run (fun sw ->
      Expiry.For_testing.start_with_observation ~sw ~clock ~state
        ~sleep_retry:(Eio.Time.sleep clock)
        ~sleep_until:(fun ~on_armed:_ _ -> failwith "no deadline expected")
        ~read:(fun _ ->
          incr reads;
          if !reads = 2 then begin Eio.Promise.resolve publish_started (); Eio.Promise.await release end;
          Ok [])
        ~invalidate:(fun ~base_path:_ -> ())
        ~observation_changed:(fun ~base_path:_ -> ());
      wait_for clock (fun () -> observation config = Observation.Observed);
      check bool "another workspace is not covered by this observer" true
        (observation other_config = Observation.Workspace_unobserved);
      let invalid_config = { config with base_path = "" } in
      check bool "an invalid workspace path is not treated as a foreign workspace" true
        (observation invalid_config = Observation.Scope_unavailable);
      let other_rows =
        Yojson.Safe.Util.(Server_keeper_waiting_inventory.dashboard_json other_config
          |> member "global_waiting_on" |> to_list) in
      check bool "the unobserved workspace has an actionable status" true
        (List.exists (fun row ->
          Yojson.Safe.Util.(row |> member "source" |> to_string) = "observation_unavailable"
          && Yojson.Safe.Util.(row |> member "next_action" |> to_string) = "switch_to_workspace")
          other_rows);
      let old = Masc.Mcp_server.workspace_scope state in
      Masc.Mcp_server.set_workspace_config state old.config |> Result.get_ok;
      check bool "same path with a new epoch is not yet observed" true
        (observation config = Observation.Initializing);
      Eio.Time.with_timeout_exn clock 2.0 (fun () -> Eio.Promise.await started);
      check bool "old observation stays unavailable while the new read waits" true
        (observation config = Observation.Initializing);
      Eio.Promise.resolve publish_release ();
      wait_for clock (fun () -> observation config = Observation.Observed)))

let test_publication_during_read_cannot_publish_old_observation () =
  with_workspace (fun env state config ->
    let clock = Eio.Stdenv.clock env in
    let first_started, publish_first_started = Eio.Promise.create () in
    let first_release, publish_first_release = Eio.Promise.create () in
    let second_started, publish_second_started = Eio.Promise.create () in
    let second_release, publish_second_release = Eio.Promise.create () in
    let reads = ref 0 in
    Eio.Switch.run (fun sw ->
      Expiry.For_testing.start_with_observation ~sw ~clock ~state
        ~sleep_retry:(Eio.Time.sleep clock)
        ~sleep_until:(fun ~on_armed:_ _ -> failwith "no deadline expected")
        ~read:(fun _ ->
          incr reads;
          (match !reads with
           | 1 -> Eio.Promise.resolve publish_first_started (); Eio.Promise.await first_release
           | 2 -> Eio.Promise.resolve publish_second_started (); Eio.Promise.await second_release
           | _ -> ());
          Ok [])
        ~invalidate:(fun ~base_path:_ -> ())
        ~observation_changed:(fun ~base_path:_ -> ());
      Eio.Promise.await first_started;
      Store.write_pending_confirms config [] |> Result.get_ok;
      Eio.Promise.resolve publish_first_release ();
      Eio.Time.with_timeout_exn clock 2.0 (fun () -> Eio.Promise.await second_started);
      check bool "the superseded read did not mark the source observed" true
        (observation config = Observation.Initializing);
      Eio.Promise.resolve publish_second_release ();
      wait_for clock (fun () -> observation config = Observation.Observed);
      Eio.Time.sleep clock 0.1;
      check int "the coalesced change causes one replacement read" 2 !reads))

let test_inventory_read_crossing_publication_is_unavailable () =
  with_workspace (fun env state config ->
    let clock = Eio.Stdenv.clock env in
    let started, publish_started = Eio.Promise.create () in
    let release, publish_release = Eio.Promise.create () in
    let result, publish_result = Eio.Promise.create () in
    let previous_reader =
      Atomic.exchange Workspace_hooks.operator_pending_confirm_read_result_fn
        (fun _ ->
          Eio.Promise.resolve publish_started ();
          Eio.Promise.await release;
          Ok []) in
    Fun.protect
      ~finally:(fun () -> Atomic.set Workspace_hooks.operator_pending_confirm_read_result_fn previous_reader)
      (fun () ->
        Eio.Switch.run (fun sw ->
          Expiry.For_testing.start_with_observation ~sw ~clock ~state
            ~sleep_until:(fun ~on_armed:_ _ -> failwith "no deadline expected")
            ~sleep_retry:(Eio.Time.sleep clock)
            ~read:(fun config -> Ok (Store.raw_pending_confirms config))
            ~invalidate:(fun ~base_path:_ -> ())
            ~observation_changed:(fun ~base_path:_ -> ());
          wait_for clock (fun () -> observation config = Observation.Observed);
          Eio.Fiber.fork ~sw (fun () ->
            Eio.Promise.resolve publish_result (Server_keeper_waiting_inventory.dashboard_json config));
          Eio.Time.with_timeout_exn clock 2.0 (fun () -> Eio.Promise.await started);
          Store.write_pending_confirms config [fixture ~token:"new" ~expires_at:None]
          |> Result.get_ok;
          wait_for clock (fun () -> observation config = Observation.Observed);
          Eio.Promise.resolve publish_release ();
          let inventory = Eio.Time.with_timeout_exn clock 3.0 (fun () -> Eio.Promise.await result) in
          check bool "a crossed read does not claim a known confirmation count" false
            Yojson.Safe.Util.(inventory |> member "global_pending_confirm_count_known" |> to_bool);
          let rows = Yojson.Safe.Util.(inventory |> member "global_waiting_on" |> to_list) in
          check bool "the crossed read is reported as unavailable" true
            (List.exists (fun row ->
              Yojson.Safe.Util.(row |> member "source" |> to_string) = "observation_unavailable"
              && Yojson.Safe.Util.(row |> member "detail" |> member "kind" |> to_string)
                 = "changed_during_read") rows))))

let test_inventory_read_crossing_deadline_is_unavailable () =
  with_workspace (fun env state config ->
    let clock = Eio.Stdenv.clock env in
    let text, _ = future_time clock 20.0 in
    let deadline, fire_deadline = Eio.Promise.create () in
    let started, publish_started = Eio.Promise.create () in
    let release, publish_release = Eio.Promise.create () in
    let result, publish_result = Eio.Promise.create () in
    let reads = ref 0 in
    let previous_reader =
      Atomic.exchange Workspace_hooks.operator_pending_confirm_read_result_fn
        (fun _ ->
          Eio.Promise.resolve publish_started ();
          Eio.Promise.await release;
          Ok []) in
    Fun.protect
      ~finally:(fun () -> Atomic.set Workspace_hooks.operator_pending_confirm_read_result_fn previous_reader)
      (fun () ->
        Eio.Switch.run (fun sw ->
          Expiry.For_testing.start_with_observation ~sw ~clock ~state
            ~sleep_until:(fun ~on_armed _ -> on_armed (); Eio.Promise.await deadline)
            ~sleep_retry:(Eio.Time.sleep clock)
            ~read:(fun _ ->
              incr reads;
              if !reads = 1 then Ok [fixture ~token:"deadline" ~expires_at:(Some text)]
              else Ok [])
            ~invalidate:(fun ~base_path:_ -> ())
            ~observation_changed:(fun ~base_path:_ -> ());
          wait_for clock (fun () -> observation config = Observation.Observed);
          Eio.Fiber.fork ~sw (fun () ->
            Eio.Promise.resolve publish_result (Server_keeper_waiting_inventory.dashboard_json config));
          Eio.Time.with_timeout_exn clock 2.0 (fun () -> Eio.Promise.await started);
          Eio.Promise.resolve fire_deadline ();
          wait_for clock (fun () -> !reads >= 2 && observation config = Observation.Observed);
          Eio.Promise.resolve publish_release ();
          let inventory = Eio.Time.with_timeout_exn clock 3.0 (fun () -> Eio.Promise.await result) in
          check bool "a deadline-crossing read has an unknown confirmation count" false
            Yojson.Safe.Util.(inventory |> member "global_pending_confirm_count_known" |> to_bool);
          let rows = Yojson.Safe.Util.(inventory |> member "global_waiting_on" |> to_list) in
          check bool "the crossed deadline is reported as unavailable" true
            (List.exists (fun row ->
              Yojson.Safe.Util.(row |> member "source" |> to_string) = "observation_unavailable"
              && Yojson.Safe.Util.(row |> member "detail" |> member "kind" |> to_string)
                 = "changed_during_read") rows))))

let () =
  run "pending-confirm expiry"
    [ "event-driven wakeup",
      [ test_case "deadline and idle" `Quick test_deadline_and_idle
      ; test_case "change rearms and foreign stays isolated" `Quick
          test_change_rearms_and_foreign_does_not_wake
      ; test_case "retired workspace discards an old read" `Quick
          test_replaced_workspace_discards_old_read
      ; test_case "failed source accepts publication during backoff" `Quick
          test_failed_read_waits_for_publication
      ; test_case "unavailable wall timer accepts publication during backoff" `Quick
          test_unavailable_wall_timer_waits_for_publication
      ; test_case "failed source recovers without publication" `Quick
          test_failed_read_recovers_without_publication
      ; test_case "unavailable timer recovers without publication" `Quick
          test_unavailable_wall_timer_recovers_without_publication
      ; test_case "workspace replacement cancels retry" `Quick
          test_replaced_workspace_cancels_retry
      ; test_case "timer failure still notifies expiry" `Quick
          test_timer_failure_still_notifies_expiry
      ; test_case "expired entry at startup wakes once" `Quick
          test_expired_at_start_wakes_once
      ; test_case "publication during read rearms deadline" `Quick
          test_publication_during_read_rearms_deadline
      ; test_case "non-Eio failed attempt wakes worker" `Quick
          test_non_eio_failed_attempt_wakes_worker
      ; test_case "persisted deadline wakes full health" `Quick
          test_persisted_deadline_wakes_full_health
      ; test_case "store and deadline publish scoped SSE" `Quick
          test_store_and_deadline_publish_scoped_sse
      ; test_case "shutdown preserves successor observer" `Quick
          test_shutdown_preserves_successor_observer
      ; test_case "observation revision tracks provider replacement" `Quick
          test_observation_revision_tracks_provider_replacement
      ; test_case "deadline observation failure and recovery" `Quick
          test_deadline_observation_failure_and_recovery
      ; test_case "read observation failure and recovery" `Quick
          test_read_observation_failure_and_recovery
      ; test_case "elapsed deadline withdraws observation until next read" `Quick
          test_elapsed_deadline_withdraws_observation_until_next_read
      ; test_case "observation expires before the timer fiber runs" `Quick
          test_observation_expires_before_the_timer_fiber_runs
      ; test_case "observation does not cross workspace epoch" `Quick
          test_observation_does_not_cross_workspace_epoch
      ; test_case "publication during read cannot publish old observation" `Quick
          test_publication_during_read_cannot_publish_old_observation
      ; test_case "inventory read crossing a publication is unavailable" `Quick
          test_inventory_read_crossing_publication_is_unavailable
      ; test_case "inventory read crossing a deadline is unavailable" `Quick
          test_inventory_read_crossing_deadline_is_unavailable
      ] ]
