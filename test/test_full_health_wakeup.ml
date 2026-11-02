open Alcotest

module Runtime = Server_routes_http_runtime

let reset () =
  Runtime.For_testing.reset_full_health_snapshot ();
  ignore (Runtime.For_testing.take_full_health_wakeup_nonblocking ())
;;

let test_non_eio_invalidation_wakes_waiter () =
  Eio_main.run (fun env ->
    reset ();
    let waiting, mark_waiting = Eio.Promise.create () in
    let non_eio = ref false in
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10.0 (fun () ->
      Eio.Fiber.both
        (fun () ->
          Eio.Promise.resolve mark_waiting ();
          Runtime.For_testing.take_full_health_wakeup ())
        (fun () ->
          Eio.Promise.await waiting;
          non_eio :=
            Eio.Domain_manager.run_raw (Eio.Stdenv.domain_mgr env) (fun () ->
              let outside_eio =
                match Fs_compat.execution_context () with
                | Non_eio -> true
                | Eio_fiber -> false
              in
              Runtime.invalidate_full_health_snapshot ();
              outside_eio)));
    check bool "invalidation ran outside Eio" true !non_eio;
    let _, _, _, _, _, requested = Runtime.For_testing.full_health_refresh_worker_stats () in
    check bool "invalidation requested a refresh" true requested)
;;

let test_committed_registry_failure_wakes_health () =
  let module Registry = Masc.Keeper_registry in
  let base_path = Masc_test_deps.setup_test_workspace () in
  let other_path = Filename.concat base_path "other-workspace" in
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  Fun.protect
    ~finally:(fun () ->
      Registry.install_state_change_observer (fun ~base_path:_ _ -> ());
      Registry.For_testing.clear ();
      reset ();
      Server_auth.For_testing.restore_server_state previous_state;
      Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
      Unix.mkdir other_path 0o755;
      Unix.mkdir (Filename.concat other_path Common.masc_dirname) 0o755;
      let state = Masc.Mcp_server.For_testing.create_state ~base_path in
      Server_auth.For_testing.restore_server_state (Some state);
      Registry.For_testing.clear ();
      let meta =
        match Masc_test_deps.meta_of_json_fixture
          (`Assoc [ "name", `String "health-observer"
                  ; "trace_id", `String "trace-health-observer"
                  ; "activation_mode", `String "manual" ]) with
        | Ok meta -> meta
        | Error error -> fail error
      in
      ignore (Registry.For_testing.register ~base_path meta.name meta);
      ignore (Registry.For_testing.register ~base_path:other_path meta.name meta);
      reset ();
      Registry.install_state_change_observer
        Runtime.invalidate_full_health_snapshot_for_registry_change;
      Eio_main.run (fun _env ->
        Eio.Switch.run (fun sw ->
          Runtime.For_testing.run_full_health_refresh_worker ~sw
            ~compute:(fun () -> Ok [ "workspace_marker", `String "current" ])));
      let _, _, _, generation, has_snapshot, requested =
        Runtime.For_testing.full_health_refresh_worker_stats () in
      check bool "current workspace has a published snapshot" true has_snapshot;
      check bool "published snapshot needs no refresh" false requested;
      Registry.set_failure_reason ~base_path:other_path meta.name
        (Some (Registry.Exception "other workspace"));
      check bool "another workspace does not wake this health worker" false
        (Runtime.For_testing.take_full_health_wakeup_nonblocking ());
      let _, _, _, after_other, _, _ =
        Runtime.For_testing.full_health_refresh_worker_stats () in
      check int "another workspace does not invalidate the snapshot"
        generation after_other;
      Registry.set_failure_reason ~base_path meta.name
        (Some (Registry.Turn_configuration_error
          { code = "invalid"; field = None; detail = "test" }));
      check bool "committed failure wakes the health worker" true
        (Runtime.For_testing.take_full_health_wakeup_nonblocking ());
      let _, _, _, _, _, requested =
        Runtime.For_testing.full_health_refresh_worker_stats () in
      check bool "committed failure invalidates the snapshot" true requested;
      Registry.set_failure_reason ~base_path "missing" (Some Registry.Operator_interrupt);
      check bool "missing keeper does not wake the worker" false
        (Runtime.For_testing.take_full_health_wakeup_nonblocking ());
      Eio_main.run (fun _env ->
        Eio.Switch.run (fun sw ->
          Runtime.For_testing.run_full_health_refresh_worker ~sw
            ~compute:(fun () -> Ok [ "workspace_marker", `String "current" ])));
      let _, _, _, _, has_snapshot, requested =
        Runtime.For_testing.full_health_refresh_worker_stats () in
      check bool "current workspace has a fresh snapshot before phase change" true
        (has_snapshot && not requested);
      (match Registry.dispatch_event ~base_path:other_path meta.name
        (Keeper_state_machine.Turn_failed { consecutive = 1 }) with
       | Ok _ -> ()
       | Error _ -> fail "other workspace lifecycle transition was rejected");
      check bool "lifecycle transition preserves global invalidation" true
        (Runtime.For_testing.take_full_health_wakeup_nonblocking ()))
;;

let test_registry_membership_wakes_health () =
  let module Registry = Masc.Keeper_registry in
  let base_path = Masc_test_deps.setup_test_workspace () in
  let other_path = Filename.concat base_path "other-workspace" in
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  Fun.protect
    ~finally:(fun () ->
      Registry.install_state_change_observer (fun ~base_path:_ _ -> ());
      Registry.For_testing.clear ();
      reset ();
      Server_auth.For_testing.restore_server_state previous_state;
      Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
      Unix.mkdir other_path 0o755;
      Unix.mkdir (Filename.concat other_path Common.masc_dirname) 0o755;
      let state = Masc.Mcp_server.For_testing.create_state ~base_path in
      Server_auth.For_testing.restore_server_state (Some state);
      Registry.For_testing.clear ();
      reset ();
      Registry.install_state_change_observer
        Runtime.invalidate_full_health_snapshot_for_registry_change;
      let hub =
        match Runtime.fleet_stream_hub_for_scope
          ~state ~scope:(Masc.Mcp_server.workspace_scope state) with
        | Some hub -> hub
        | None -> fail "current workspace fleet hub was unavailable"
      in
      ignore (Runtime.For_testing.take_full_health_wakeup_nonblocking ());
      let fleet_paused_counts = ref [] in
      let unsubscribe = Masc.Fleet_stream_hub.subscribe hub ~on_event:(function
        | Masc.Fleet_stream.Snapshot { fleet; _ }
        | Masc.Fleet_stream.Changed { fleet; _ } ->
          fleet_paused_counts := fleet.fs_paused_count :: !fleet_paused_counts
        | Masc.Fleet_stream.Unavailable_snapshot _ | Masc.Fleet_stream.Degraded _ -> ())
      in
      let refresh () =
        Eio_main.run (fun _env ->
          Eio.Switch.run (fun sw ->
            Runtime.For_testing.run_full_health_refresh_worker ~sw
              ~compute:(fun () ->
                Ok (Runtime.keeper_fleet_runtime_resolution_light_fields ()))))
      in
      refresh ();
      check (list int) "initial fleet reports no paused keepers" [ 0 ]
        (List.rev !fleet_paused_counts);
      let meta =
        match Masc_test_deps.meta_of_json_fixture
          (`Assoc [ "name", `String "membership-observer"
                  ; "trace_id", `String "trace-membership-observer"
                  ; "activation_mode", `String "manual"
                  ; "paused", `Bool true ]) with
        | Ok meta -> meta
        | Error error -> fail error
      in
      let entry = Registry.For_testing.register ~base_path:other_path meta.name meta in
      check bool "other workspace registration changes global paused inventory" true
        (List.mem meta.name (Server_routes_http_runtime_fleet_scan.registry_paused_keeper_names ()));
      check bool "registration wakes the health worker" true
        (Runtime.For_testing.take_full_health_wakeup_nonblocking ());
      let _, _, _, _, _, requested =
        Runtime.For_testing.full_health_refresh_worker_stats () in
      check bool "registration invalidates the published snapshot" true requested;
      refresh ();
      check (list int) "fleet subscriber sees the registered keeper" [ 0; 1 ]
        (List.rev !fleet_paused_counts);
      (match Registry.unregister_exact entry with
       | Registry.Exact_unregistered -> ()
       | _ -> fail "registered keeper could not be removed");
      check bool "removal changes global paused inventory" false
        (List.mem meta.name (Server_routes_http_runtime_fleet_scan.registry_paused_keeper_names ()));
      check bool "removal wakes the health worker" true
        (Runtime.For_testing.take_full_health_wakeup_nonblocking ());
      refresh ();
      check (list int) "fleet subscriber sees the removal" [ 0; 1; 0 ]
        (List.rev !fleet_paused_counts);
      (match Registry.unregister_exact entry with
       | Registry.Exact_entry_missing -> ()
       | _ -> fail "removed keeper was not missing");
      check bool "a missing entry does not wake the worker" false
        (Runtime.For_testing.take_full_health_wakeup_nonblocking ());
      unsubscribe ())
;;

let test_owner_metadata_wakes_fleet_subscriber () =
  let module Registry = Masc.Keeper_registry in
  let module Owner = Masc.Keeper_owner in
  let module Owners = Masc.Keeper_owner_registry in
  let base_path = Masc_test_deps.setup_test_workspace () in
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  let previous_fs = Fs_compat.get_fs_opt () in
  Fun.protect
    ~finally:(fun () ->
      Owner.install_state_change_observer ignore;
      Registry.For_testing.clear ();
      reset ();
      Server_auth.For_testing.restore_server_state previous_state;
      (match previous_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ());
      Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
      let state = Masc.Mcp_server.For_testing.create_state ~base_path in
      Server_auth.For_testing.restore_server_state (Some state);
      Registry.For_testing.clear ();
      Eio_main.run (fun env ->
        Fs_compat.set_fs (Eio.Stdenv.fs env);
        Eio.Switch.run (fun sw ->
          let config = Masc.Mcp_server.workspace_config state in
          ignore (Workspace_core.init config ~agent_name:(Some "test"));
          (match Owners.install_from_store ~sw ~operation_runner:None
             ~on_turn_slot_released:None config with
           | Ok 0 -> ()
           | Ok _ -> fail "expected an empty owner inventory"
           | Error error -> fail (Owners.install_error_to_string error));
          let meta =
            match Masc_test_deps.meta_of_json_fixture
              (`Assoc [ "name", `String "health-owner-meta"
                      ; "trace_id", `String "trace-health-owner-meta"
                      ; "activation_mode", `String "manual" ]) with
            | Ok meta -> meta
            | Error error -> fail error
          in
          (match Owners.create_meta ~base_path meta with
           | Ok (Some _) -> ()
           | Ok None -> fail "owner did not create metadata"
           | Error error -> fail (Owners.command_error_to_string error));
          ignore (Registry.For_testing.register ~base_path meta.name meta);
          reset ();
          let hub =
            match Runtime.fleet_stream_hub_for_scope
              ~state ~scope:(Masc.Mcp_server.workspace_scope state) with
            | Some hub -> hub
            | None -> fail "current workspace fleet hub was unavailable"
          in
          ignore (Runtime.For_testing.take_full_health_wakeup_nonblocking ());
          let counts = ref [] in
          let unsubscribe = Masc.Fleet_stream_hub.subscribe hub ~on_event:(function
            | Masc.Fleet_stream.Snapshot { fleet; _ }
            | Masc.Fleet_stream.Changed { fleet; _ } ->
              counts := fleet.fs_paused_count :: !counts
            | Masc.Fleet_stream.Unavailable_snapshot _ | Masc.Fleet_stream.Degraded _ -> ())
          in
          let refresh () =
            Runtime.For_testing.run_full_health_refresh_worker ~sw ~compute:(fun () ->
              Ok (Runtime.keeper_fleet_runtime_resolution_light_fields ()))
          in
          refresh ();
          Owner.install_state_change_observer Runtime.invalidate_full_health_snapshot;
          (* Calling the Owner directly leaves the registry's stored entry at
             its initial value, so the fleet read must use the Owner overlay. *)
          let owner =
            match Owners.get ~base_path ~keeper_name:meta.name with
            | Ok owner -> owner
            | Error error -> fail (Owners.lookup_error_to_string error)
          in
          let apply command =
            match Owner.apply_meta owner command with
            | Ok (Some _) -> ()
            | Ok None -> fail "owner metadata disappeared"
            | Error error -> fail (Owner.error_to_string error)
          in
          apply (Masc.Keeper_owner_reducer.Pause
            { reason = Keeper_latched_reason.Operator_paused { operator_actor = Grpc_directive }
            ; updated_at = "2026-11-02T00:00:00Z" });
          check bool "registry health reads the paused Owner overlay" true
            (List.mem meta.name (Server_routes_http_runtime_fleet_scan.registry_paused_keeper_names ()));
          check bool "owner pause wakes the health worker" true
            (Runtime.For_testing.take_full_health_wakeup_nonblocking ());
          refresh ();
          apply (Masc.Keeper_owner_reducer.Resume { updated_at = "2026-11-02T00:00:01Z" });
          check bool "registry health reads the resumed Owner overlay" false
            (List.mem meta.name (Server_routes_http_runtime_fleet_scan.registry_paused_keeper_names ()));
          check bool "owner resume wakes the health worker" true
            (Runtime.For_testing.take_full_health_wakeup_nonblocking ());
          refresh ();
          check (list int) "real owner changes reach the fleet subscriber" [ 0; 1; 0 ]
            (List.rev !counts);
          unsubscribe ())))
;;

let test_non_eio_wakes_coalesce_without_blocking () =
  Eio_main.run (fun env ->
    reset ();
    let started = Atomic.make 0 and release = Atomic.make false in
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10.0 (fun () ->
      Eio.Fiber.both
        (fun () ->
          Eio.Fiber.all
            (List.init 8 (fun _ -> fun () ->
              Eio.Domain_manager.run_raw (Eio.Stdenv.domain_mgr env) (fun () ->
                Atomic.incr started;
                let deadline = Unix.gettimeofday () +. 5.0 in
                while not (Atomic.get release) && Unix.gettimeofday () < deadline do
                  Domain.cpu_relax ()
                done;
                if not (Atomic.get release) then failwith "producer barrier timed out";
                for _ = 1 to 100 do Runtime.invalidate_full_health_snapshot () done))))
        (fun () ->
          while Atomic.get started < 8 do Eio.Fiber.yield () done;
          Atomic.set release true));
    check bool "one wake was retained" true
      (Runtime.For_testing.take_full_health_wakeup_nonblocking ());
    check bool "wakes coalesced into one mailbox slot" false
      (Runtime.For_testing.take_full_health_wakeup_nonblocking ()))
;;

let test_non_eio_invalidation_runs_refresh_worker () =
  Eio_main.run (fun env ->
    reset ();
    let warm, mark_warm = Eio.Promise.create () in
    let refreshed, mark_refreshed = Eio.Promise.create () in
    let producing, mark_producing = Eio.Promise.create () in
    let never, _ = Eio.Promise.create () in
    let results = ref 0 in
    let running = Atomic.make false and stop = Atomic.make false in
    let refreshed_while_running = ref false in
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10.0 (fun () ->
      Eio.Fiber.first
        (fun () ->
          Eio.Switch.run (fun sw ->
            let config =
              { (Proactive_refresh.default_config ~label:"test-health-wakeup" ~interval_s:60.0) with
                timeout_s = 5.0
              ; wakeup = Some (Runtime.For_testing.full_health_wakeup_stream ())
              ; wakeup_coalesce_s = 0.05
              }
            in
            Proactive_refresh.start ~sw ~clock:(Eio.Stdenv.clock env)
              ~config ~compute:(fun () -> ()) ~on_result:(fun () ->
                incr results;
                if !results = 1 then Eio.Promise.resolve mark_warm ()
                else if !results = 2 then (
                  refreshed_while_running := Atomic.get running;
                  Eio.Promise.resolve mark_refreshed ()));
            Eio.Promise.await never))
        (fun () ->
          Eio.Promise.await warm;
          Eio.Fiber.both
            (fun () ->
              Eio.Domain_manager.run_raw (Eio.Stdenv.domain_mgr env) (fun () ->
                Atomic.set running true;
                Eio.Promise.resolve mark_producing ();
                let deadline = Unix.gettimeofday () +. 8.0 in
                while not (Atomic.get stop) && Unix.gettimeofday () < deadline do
                  Runtime.invalidate_full_health_snapshot ()
                done;
                Atomic.set running false))
            (fun () ->
              Eio.Promise.await producing;
              Eio.Promise.await refreshed;
              Atomic.set stop true)));
    check bool "refresh ran while the non-Eio producer remained active"
      true !refreshed_while_running)
;;

let test_approval_count_wakes_only_its_workspace () =
  let module Waiting = Masc.Keeper_waiting_inventory_broadcast in
  let base_path = Masc_test_deps.setup_test_workspace () in
  let other_path = Filename.concat base_path "other-approval-workspace" in
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  Fun.protect
    ~finally:(fun () ->
      Waiting.install_health_change_observer (fun ~base_path:_ -> ());
      reset ();
      Server_auth.For_testing.restore_server_state previous_state;
      Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
      Unix.mkdir other_path 0o755;
      Unix.mkdir (Filename.concat other_path Common.masc_dirname) 0o755;
      let state = Masc.Mcp_server.For_testing.create_state ~base_path in
      Server_auth.For_testing.restore_server_state (Some state);
      Waiting.install_health_change_observer
        Runtime.invalidate_full_health_snapshot_for_workspace;
      reset ();
      Waiting.changed ~base_path:other_path ~keeper_name:"other" ~source:Approval_count;
      check bool "another workspace does not wake health" false
        (Runtime.For_testing.take_full_health_wakeup_nonblocking ());
      Waiting.changed ~base_path ~keeper_name:"current" ~source:Approval_detail;
      check bool "approval detail alone does not change health counts" false
        (Runtime.For_testing.take_full_health_wakeup_nonblocking ());
      Waiting.changed ~base_path:(Filename.concat base_path Common.masc_dirname)
        ~keeper_name:"current" ~source:Approval_count;
      check bool "canonical matching workspace wakes health" true
        (Runtime.For_testing.take_full_health_wakeup_nonblocking ());
      let _, _, _, _, _, requested = Runtime.For_testing.full_health_refresh_worker_stats () in
      check bool "matching approval count invalidates the snapshot" true requested)
;;

let test_approval_health_callback_preserves_scope_cancellation () =
  let module Waiting = Masc.Keeper_waiting_inventory_broadcast in
  let original_buffer = Masc.Sse.event_buffer_events_for_test () in
  Fun.protect
    ~finally:(fun () ->
      Waiting.install_health_change_observer (fun ~base_path:_ -> ());
      Masc.Sse.set_event_buffer_for_test original_buffer)
    (fun () ->
      Eio_main.run (fun _env ->
        Waiting.install_health_change_observer (fun ~base_path:_ ->
          raise (Eio.Cancel.Cancelled Exit));
        let before = Masc.Sse.current_id () in
        Waiting.changed ~base_path:"/tmp/approval-observer-cancel"
          ~keeper_name:"current" ~source:Approval_count;
        check bool "callback-only cancellation does not suppress the event" true
          (Masc.Sse.current_id () > before);
        let reason = Failure "cancelled caller" in
        (match Eio.Cancel.sub (fun context ->
           Waiting.install_health_change_observer (fun ~base_path:_ ->
             Eio.Cancel.cancel context reason;
             raise (Eio.Cancel.Cancelled Exit));
           Waiting.changed ~base_path:"/tmp/approval-observer-cancel"
             ~keeper_name:"current" ~source:Approval_count) with
         | () -> fail "caller cancellation did not propagate"
         | exception Eio.Cancel.Cancelled actual when actual == reason -> ()
         | exception exn -> fail ("unexpected cancellation: " ^ Printexc.to_string exn))))
;;

let test_schedule_publication_wakes_its_workspace () =
  let base_path = Masc_test_deps.setup_test_workspace () in
  let other_path = Filename.concat base_path "other-schedule-workspace" in
  let current_session = "schedule-invalidation-current" in
  let other_session = "schedule-invalidation-other" in
  let external_id = "schedule-invalidation-external" in
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  let previous_fs = Fs_compat.get_fs_opt () in
  Fun.protect
    ~finally:(fun () ->
      Schedule_store.install_change_observer (fun ~base_path:_ -> ());
      Masc.Sse.unsubscribe_external external_id;
      Masc.Sse.unregister current_session;
      Masc.Sse.unregister other_session;
      ignore (Masc.Session.McpSessionStore.remove current_session);
      ignore (Masc.Session.McpSessionStore.remove other_session);
      reset ();
      Server_auth.For_testing.restore_server_state previous_state;
      (match previous_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ());
      Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
      Unix.mkdir other_path 0o755;
      let state = Masc.Mcp_server.For_testing.create_state ~base_path in
      Server_auth.For_testing.restore_server_state (Some state);
      Eio_main.run (fun env ->
        Fs_compat.set_fs (Eio.Stdenv.fs env);
        let current = Masc.Mcp_server.workspace_config state in
        let other = Workspace_core.default_config other_path in
        ignore (Workspace_core.init current ~agent_name:(Some "test"));
        ignore (Workspace_core.init other ~agent_name:(Some "test"));
        let register path session_id =
          let auth = Masc_test_deps.make_sse_auth path "schedule-invalidation-test" in
          ignore (Masc.Session.McpSessionStore.get_or_create ~id:session_id ());
          match Masc.Sse.register ~kind:Observer ~auth session_id ~last_event_id:0 with
          | Ok (_, stream, _) -> stream
          | Error error -> fail (Masc.Sse.registration_error_to_string error)
        in
        let current_stream = register base_path current_session in
        let other_stream = register other_path other_session in
        let authority = Masc.Sse.runtime_authority_exn ~base_path in
        let external_calls = ref 0 in
        Masc.Sse.subscribe_external ~runtime_authority:authority ~id:external_id
          ~callback:(fun _ -> incr external_calls) ();
        Eio.Switch.run (fun sw ->
        Server_schedule_invalidation.start ~sw;
        reset ();
        let before_id = Masc.Sse.current_id () in
        let receive stream =
          Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5.0
            (fun () -> Masc.Sse.take_delivery stream) in
        let actor : Schedule_domain.actor =
          { id = "test"; kind = Schedule_domain.Human_operator; display_name = None } in
        let insert config schedule_id =
          let request = match Schedule_domain.create_request ~schedule_id
            ~requested_by:actor ~scheduled_by:actor ~requested_at:100.0 ~due_at:200.0
            ~payload:(`Assoc [ "kind", `String "consumer.note"; "body", `Assoc [] ])
            ~source:Schedule_domain.Operator_request () with
            | Ok request -> request
            | Error err -> fail err in
          match Schedule_store.insert_request config ~runner_tick_sec:1.0 request with
          | Ok _ -> ()
          | Error err -> fail (Schedule_store.store_error_to_string err)
        in
        insert other "other";
        check bool "foreign publication does not wake current health" false
          (Runtime.For_testing.take_full_health_wakeup_nonblocking ());
        let other_delivery = receive other_stream in
        check bool "foreign publication does not reach current observer" true
          (Option.is_none (Masc.Sse.take_delivery_nonblocking current_stream));
        check bool "foreign observer receives its change" true
          (other_delivery.payload = Masc.Schedule_invalidation_event.json);
        insert current "current";
        check bool "current publication wakes health" true
          (Runtime.For_testing.take_full_health_wakeup_nonblocking ());
        let current_delivery = receive current_stream in
        check bool "current observer receives its change" true
          (current_delivery.payload = Masc.Schedule_invalidation_event.json);
        check bool "current publication does not reach foreign observer" true
          (Option.is_none (Masc.Sse.take_delivery_nonblocking other_stream));
        check int "schedule writes do not invoke external callbacks" 0 !external_calls;
        let replay = Masc.Sse.replay_after_for_session ~runtime_authority:authority
          ~session_id:current_session ~kind:Observer before_id in
        check int "only the current workspace change is replayed" 1 (List.length replay.deliveries);
        (match replay.deliveries with
         | [delivery] -> check bool "replayed event is the invalidation" true
             (delivery.payload = Masc.Schedule_invalidation_event.json)
         | [] | _ :: _ :: _ -> fail "expected one scoped replay event");
        (match Schedule_store.refresh_due current ~now:150.0
          ~retention_days:Schedule_store.terminal_schedule_retention_days with
         | Ok _ -> ()
         | Error err -> fail (Schedule_store.store_error_to_string err));
        check bool "quiet tick does not wake health" false
          (Runtime.For_testing.take_full_health_wakeup_nonblocking ());
        check bool "quiet tick does not publish a change" true
          (Option.is_none (Masc.Sse.take_delivery_nonblocking current_stream)))))
;;

let test_schedule_worker_coalesces_and_preserves_successor () =
  let base_path = Masc_test_deps.setup_test_workspace () in
  let previous_fs = Fs_compat.get_fs_opt () in
  Fun.protect
    ~finally:(fun () ->
      Schedule_store.install_change_observer (fun ~base_path:_ -> ());
      (match previous_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ());
      Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
      Eio_main.run (fun env ->
        Fs_compat.set_fs (Eio.Stdenv.fs env);
        let config = Workspace_core.default_config base_path in
        ignore (Workspace_core.init config ~agent_name:(Some "test"));
        let actor : Schedule_domain.actor =
          { id = "test"; kind = Schedule_domain.Human_operator; display_name = None } in
        let insert schedule_id =
          let request = match Schedule_domain.create_request ~schedule_id
            ~requested_by:actor ~scheduled_by:actor ~requested_at:100.0 ~due_at:200.0
            ~payload:(`Assoc [ "kind", `String "consumer.note"; "body", `Assoc [] ])
            ~source:Schedule_domain.Operator_request () with
            | Ok request -> request
            | Error err -> fail err in
          match Schedule_store.insert_request config ~runner_tick_sec:1.0 request with
          | Ok _ -> ()
          | Error err -> fail (Schedule_store.store_error_to_string err) in
        let started = Eio.Stream.create 4 in
        let release, release_u = Eio.Promise.create () in
        let publications = ref 0 and successor_calls = ref 0 in
        Eio.Switch.run (fun sw ->
          Server_schedule_invalidation.For_testing.start ~sw
            ~invalidate:(fun ~base_path:_ -> ())
            ~publish:(fun ~base_path ->
              incr publications;
              Eio.Stream.add started base_path;
              if !publications = 1 then Eio.Promise.await release
              else if !publications = 2 then raise (Eio.Cancel.Cancelled Exit));
          let receive () =
            Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5.0
              (fun () -> Eio.Stream.take started) in
          insert "first";
          check string "first publication starts" base_path (receive ());
          insert "second";
          insert "third";
          check int "writes return while the publisher is held" 1 !publications;
          Eio.Promise.resolve release_u ();
          check string "one follow-up covers both writes" base_path (receive ());
          Eio.Fiber.yield ();
          check int "duplicate workspace signals coalesce" 2 !publications;
          insert "after-callback-cancellation";
          check string "callback cancellation does not stop the worker" base_path (receive ());
          Schedule_store.install_change_observer (fun ~base_path:_ -> incr successor_calls));
        insert "after-stop";
        check int "worker shutdown leaves a successor installed" 1 !successor_calls))
;;

let test_pending_confirm_publication_wakes_its_workspace () =
  let base_path = Masc_test_deps.setup_test_workspace () in
  let other_path = Filename.concat base_path "other-confirm-workspace" in
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  let previous_fs = Fs_compat.get_fs_opt () in
  Fun.protect
    ~finally:(fun () ->
      Operator_pending_confirm.install_change_observer (fun ~base_path:_ -> ());
      reset ();
      Server_auth.For_testing.restore_server_state previous_state;
      (match previous_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ());
      Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
      Unix.mkdir other_path 0o755;
      let state = Masc.Mcp_server.For_testing.create_state ~base_path in
      Server_auth.For_testing.restore_server_state (Some state);
      Eio_main.run (fun env ->
        Fs_compat.set_fs (Eio.Stdenv.fs env);
        let current = Masc.Mcp_server.workspace_config state in
        let other = Workspace_core.default_config other_path in
        ignore (Workspace_core.init current ~agent_name:(Some "test"));
        ignore (Workspace_core.init other ~agent_name:(Some "test"));
        Operator_pending_confirm.install_change_observer
          Runtime.invalidate_full_health_snapshot_for_workspace;
        reset ();
        Operator_pending_confirm.write_pending_confirms other [] |> Result.get_ok;
        check bool "foreign publication does not wake current health" false
          (Runtime.For_testing.take_full_health_wakeup_nonblocking ());
        Operator_pending_confirm.write_pending_confirms current [] |> Result.get_ok;
        check bool "current publication wakes health" true
          (Runtime.For_testing.take_full_health_wakeup_nonblocking ());
        ignore (Operator_pending_confirm.read_pending_confirms_result current |> Result.get_ok);
        check bool "read without cleanup does not wake health" false
          (Runtime.For_testing.take_full_health_wakeup_nonblocking ())))
;;

let () =
  let _ = Sys.signal Sys.sigalrm (Sys.Signal_handle (fun _ ->
    prerr_endline "full health wakeup test watchdog expired";
    Unix._exit 124)) in
  ignore (Unix.alarm 30);
  Fun.protect ~finally:(fun () -> ignore (Unix.alarm 0)) (fun () ->
    run "full_health_wakeup"
      [ "invalidation"
      , [ test_case "non-Eio invalidation wakes a waiting reader" `Quick
            test_non_eio_invalidation_wakes_waiter
        ; test_case "concurrent non-Eio wakes coalesce" `Quick
            test_non_eio_wakes_coalesce_without_blocking
        ; test_case "non-Eio invalidation runs refresh worker" `Quick
            test_non_eio_invalidation_runs_refresh_worker
        ; test_case "committed registry failure wakes health" `Quick
            test_committed_registry_failure_wakes_health
        ; test_case "registry membership wakes health" `Quick
            test_registry_membership_wakes_health
        ; test_case "owner metadata wakes fleet subscriber" `Quick
            test_owner_metadata_wakes_fleet_subscriber
        ; test_case "approval count wakes only its workspace" `Quick
            test_approval_count_wakes_only_its_workspace
        ; test_case "approval health callback preserves caller cancellation" `Quick
            test_approval_health_callback_preserves_scope_cancellation
        ; test_case "schedule publication wakes its workspace" `Quick
            test_schedule_publication_wakes_its_workspace
        ; test_case "schedule worker coalesces and preserves its successor" `Quick
            test_schedule_worker_coalesces_and_preserves_successor
        ; test_case "pending confirm publication wakes its workspace" `Quick
            test_pending_confirm_publication_wakes_its_workspace
        ]
      ])
