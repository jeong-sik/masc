open Alcotest

module Expiry = Server_pending_confirm_expiry
module Store = Operator_pending_confirm

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
          Expiry.start ~sw ~clock ~state;
          Eio.Fiber.yield ();
          check bool "persisted future entry does not wake early" false
            (Runtime.For_testing.take_full_health_wakeup_nonblocking ());
          Eio.Time.sleep_until clock (at +. 0.25);
          Eio.Time.with_timeout_exn clock 3.0 (fun () ->
            Runtime.For_testing.take_full_health_wakeup ());
          check int "store cleanup drops the expired entry" 0
            (List.length (Store.read_pending_confirms_result config |> Result.get_ok)))))

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

let () =
  run "pending-confirm expiry"
    [ "event-driven wakeup",
      [ test_case "deadline and idle" `Quick test_deadline_and_idle
      ; test_case "change rearms and foreign stays isolated" `Quick
          test_change_rearms_and_foreign_does_not_wake
      ; test_case "retired workspace discards an old read" `Quick
          test_replaced_workspace_discards_old_read
      ; test_case "failed source waits for publication" `Quick
          test_failed_read_waits_for_publication
      ; test_case "expired entry at startup wakes once" `Quick
          test_expired_at_start_wakes_once
      ; test_case "publication during read rearms deadline" `Quick
          test_publication_during_read_rearms_deadline
      ; test_case "non-Eio failed attempt wakes worker" `Quick
          test_non_eio_failed_attempt_wakes_worker
      ; test_case "persisted deadline wakes full health" `Quick
          test_persisted_deadline_wakes_full_health
      ; test_case "shutdown preserves successor observer" `Quick
          test_shutdown_preserves_successor_observer
      ] ]
