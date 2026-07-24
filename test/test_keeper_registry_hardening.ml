(** P0 keeper registry hardening tests.

    Verify typed validation errors on put/update, health-aware get, and exact
    turn-resource identity across same-name registry entry replacement. *)

open Alcotest

module KR = Masc.Keeper_registry
module KET = Masc.Keeper_tool_dispatch_runtime
module KLH = Masc.Keeper_lifecycle_hooks
module Keeper_lifecycle_admission = Masc.Keeper_lifecycle_admission
module Reservation = Masc.Keeper_lifecycle_reservation
module KSM = Keeper_state_machine
module Lane = Masc.Keeper_lane

let base_path = "/tmp/test_keeper_registry_hardening"

let make_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String ("agent-" ^ name));
          ("trace_id", `String ("trace-" ^ name));
          ("allowed_paths", `List [ `String "*" ]);
          ("autoboot_enabled", `Bool false);
        ])
  with
  | Ok m -> m
  | Error e -> failwith ("make_meta failed: " ^ e)
;;

let register name =
  let meta = make_meta name in
  KR.For_testing.register ~base_path meta.name meta
;;

let health_to_string = KR.registry_entry_validation_error_to_string

let test_put_entry_rejects_meta_name_mismatch () =
  KR.For_testing.clear ();
  let entry = register "alice" in
  let corrupted = { entry with meta = { entry.meta with name = "bob" } } in
  match KR.put_entry ~base_path "alice" corrupted with
  | Ok () -> fail "put_entry accepted a meta.name mismatch"
  | Error (KR.Name_mismatch { expected; actual }) ->
    check string "expected name" "alice" expected;
    check string "actual name" "bob" actual
  | Error other -> fail ("unexpected validation error: " ^ health_to_string other)
;;

let test_update_entry_rejects_corrupted_result () =
  KR.For_testing.clear ();
  let entry = register "alice" in
  let original_base_path = entry.base_path in
  (match
     KR.update_entry ~base_path "alice" (fun e -> { e with base_path = "wrong" })
   with
   | Ok () -> fail "update_entry accepted a corrupted closure result"
   | Error (KR.Base_path_mismatch _) -> ()
   | Error other -> fail ("unexpected validation error: " ^ health_to_string other));
  match KR.get ~base_path "alice" with
  | None -> fail "original entry disappeared after rejected update"
  | Some e -> check string "original base_path preserved" original_base_path e.base_path
;;

let test_unregister_exact_preserves_replacement_lane () =
  KR.For_testing.clear ();
  let old_entry = register "alice" in
  let replacement = register "alice" in
  (match KR.unregister_exact old_entry with
   | KR.Exact_entry_replaced -> ()
   | KR.Exact_unregistered -> fail "stale entry removed its replacement lane"
   | KR.Exact_entry_missing -> fail "replacement lane unexpectedly missing"
   | KR.Exact_unregister_lifecycle_reserved _ ->
     fail "test did not acquire a lifecycle reservation");
  (match KR.get ~base_path "alice" with
   | Some current ->
     check bool "replacement remains registered" true (current == replacement)
   | None -> fail "replacement lane was removed");
  match KR.unregister_exact replacement with
  | KR.Exact_unregistered -> ()
  | KR.Exact_entry_missing -> fail "replacement disappeared before exact removal"
  | KR.Exact_entry_replaced -> fail "replacement identity changed unexpectedly"
  | KR.Exact_unregister_lifecycle_reserved _ ->
    fail "test did not acquire a lifecycle reservation"
;;

let test_unregister_exact_accepts_same_lane_record_update () =
  KR.For_testing.clear ();
  let observed = register "alice" in
  (match
     KR.update_entry ~base_path "alice" (fun entry ->
       { entry with last_error = Some "immutable record replacement" })
   with
   | Ok () -> ()
   | Error error -> fail (KR.registry_entry_validation_error_to_string error));
  match KR.unregister_exact observed with
  | KR.Exact_unregistered -> ()
  | KR.Exact_entry_missing -> fail "same lane disappeared before removal"
  | KR.Exact_entry_replaced -> fail "same lane record update was treated as ABA"
  | KR.Exact_unregister_lifecycle_reserved _ ->
    fail "test did not acquire a lifecycle reservation"
;;

let test_update_entry_exact_preserves_replacement_lane () =
  KR.For_testing.clear ();
  let old_entry = register "alice" in
  let replacement = register "alice" in
  (match
     KR.update_entry_exact old_entry (fun entry ->
       { entry with last_error = Some "stale lane mutation" })
   with
   | KR.Exact_update_replaced -> ()
   | KR.Exact_updated -> fail "stale exact update mutated the replacement lane"
   | KR.Exact_update_missing -> fail "replacement lane unexpectedly missing"
   | KR.Exact_update_invalid error ->
     fail (KR.registry_entry_validation_error_to_string error));
  match KR.get ~base_path "alice" with
  | Some current ->
    check bool "replacement identity preserved" true (current == replacement);
    check (option string) "replacement error field preserved" None current.last_error
  | None -> fail "replacement lane disappeared"
;;

let test_dispatch_event_exact_preserves_replacement_lane () =
  KR.For_testing.clear ();
  let old_meta = make_meta "alice" in
  let old_entry = KR.register_offline ~base_path old_meta.name old_meta in
  let replacement = KR.register_offline ~base_path old_meta.name old_meta in
  (match KR.dispatch_event_exact old_entry KSM.Fiber_started with
   | Error _ -> ()
   | Ok _ -> fail "stale exact dispatch mutated the replacement lane");
  match KR.get ~base_path "alice" with
  | Some current ->
    check bool "replacement identity preserved" true (current == replacement);
    check
      string
      "replacement remains offline"
      "offline"
      (KSM.phase_to_string current.phase)
  | None -> fail "replacement lane disappeared"
;;

let test_lane_fork_rejects_cancelling_switch () =
  Eio_main.run @@ fun _env ->
  let lane = Lane.create () in
  let run_called = Atomic.make false in
  let cleanup_calls = Atomic.make 0 in
  let fork_result = Atomic.make None in
  (try
     Eio.Switch.run @@ fun sw ->
     Eio.Switch.fail sw (Failure "synthetic parent cancellation");
     Atomic.set
       fork_result
       (Some
          (Lane.fork
             ~sw
             lane
             ~run:(fun _ -> Atomic.set run_called true)
             ~cleanup:(fun _ ->
               Atomic.incr cleanup_calls;
               Ok ())))
   with
   | Failure _ -> ()
   | exn -> raise exn);
  (match Atomic.get fork_result with
   | Some (Error (Lane.Fork_failed _)) -> ()
   | Some (Error error) -> fail (Lane.start_error_to_string error)
   | Some (Ok ()) -> fail "fork reported success on an already-cancelling switch"
   | None -> fail "fork result was not captured");
  check bool "lane body was not run" false (Atomic.get run_called);
  check int "cleanup ran exactly once" 1 (Atomic.get cleanup_calls);
  match Lane.peek_exit lane with
  | Some { outcome = Lane.Cancelled_by_parent _; _ } -> ()
  | Some _ -> fail "lane exit did not preserve parent cancellation"
  | None -> fail "lane exit promise remained unresolved"
;;

let test_dispatch_write_failure_skips_phase_side_effects () =
  KR.For_testing.clear ();
  KLH.reset_for_testing ();
  Fun.protect
    ~finally:(fun () -> KLH.reset_for_testing ())
    (fun () ->
       let hook_calls = ref 0 in
       KLH.register (fun ~keeper_id:_ _ -> incr hook_calls);
       let entry = register "alice" in
       let corrupted = { entry with meta = { entry.meta with name = "bob" } } in
       KR.For_testing.unsafe_put_entry ~base_path "alice" corrupted;
       match KR.dispatch_event ~base_path "alice" KSM.Fiber_started with
       | Ok _ -> fail "dispatch accepted a transition whose registry write failed"
       | Error (KSM.Invalid_transition _ | KSM.Precondition_violation _) ->
         check int "phase hook skipped before failed write" 0 !hook_calls
       | Error other ->
         fail
           ( "unexpected dispatch error: "
           ^ KSM.transition_error_to_string other ))
;;

let test_get_filters_corrupted_entry () =
  KR.For_testing.clear ();
  let entry = register "alice" in
  let corrupted =
    { entry with
      meta =
        { entry.meta with
          runtime = { entry.meta.runtime with nonce = -1 }
        }
    }
  in
  KR.For_testing.unsafe_put_entry ~base_path "alice" corrupted;
  (match KR.get ~base_path "alice" with
   | None -> ()
   | Some _ -> fail "get returned a corrupted entry");
  match KR.get_with_health ~base_path "alice" with
  | None -> fail "get_with_health returned None for an existing (corrupted) entry"
  | Some (e, KR.Required_field_missing { field }) ->
    check string "missing field" "generation" field;
    check string "entry base_path" base_path e.base_path
  | Some (_, other) -> fail ("unexpected health: " ^ health_to_string other)
;;

let test_wakeup_running_reports_typed_outcome () =
  KR.For_testing.clear ();
  (match
     KR.wakeup_running ~intent:KR.Hitl_resolution ~base_path "missing"
   with
   | KR.Deferred_unregistered -> ()
   | KR.Signaled | KR.Deferred_not_running _ | KR.Deferred_lifecycle _ ->
     fail "missing keeper did not return Deferred_unregistered");
  let running = register "running" in
  Atomic.set running.fiber_wakeup false;
  (match
     KR.wakeup_running ~intent:KR.Hitl_resolution ~base_path "running"
   with
   | KR.Signaled -> check bool "running keeper is signaled" true (Atomic.get running.fiber_wakeup)
   | KR.Deferred_unregistered | KR.Deferred_not_running _
   | KR.Deferred_lifecycle _ ->
     fail "running keeper was not signaled");
  let offline_meta = make_meta "offline" in
  let offline = KR.register_offline ~base_path offline_meta.name offline_meta in
  Atomic.set offline.fiber_wakeup false;
  (match
     KR.wakeup_running ~intent:KR.Hitl_resolution ~base_path "offline"
   with
   | KR.Deferred_not_running phase ->
     check string "deferred phase is explicit" "offline" (KSM.phase_to_string phase);
     check bool "offline keeper is not signaled" false (Atomic.get offline.fiber_wakeup)
   | KR.Signaled | KR.Deferred_unregistered | KR.Deferred_lifecycle _ ->
     fail "offline keeper did not return Deferred_not_running")
;;

let test_wakeup_running_exact_preserves_owner_lane () =
  KR.For_testing.clear ();
  let captured = register "exact-owner" in
  let peer = register "exact-peer" in
  Atomic.set captured.fiber_wakeup false;
  Atomic.set peer.fiber_wakeup false;
  (match KR.wakeup_running_exact ~intent:KR.Reactive_signal captured with
   | KR.Exact_wake_signaled -> ()
   | KR.Exact_wake_missing
   | KR.Exact_wake_replaced
   | KR.Exact_wake_not_running _
   | KR.Exact_wake_lifecycle_denied _
   | KR.Exact_wake_lifecycle_reserved _ ->
     fail "current exact owner was not signaled");
  check bool "current exact owner is signaled" true (Atomic.get captured.fiber_wakeup);
  check bool "peer remains untouched" false (Atomic.get peer.fiber_wakeup);
  Atomic.set captured.fiber_wakeup false;
  (match
     KR.update_entry ~base_path "exact-owner" (fun entry ->
       { entry with last_error = Some "immutable record update" })
   with
   | Ok () -> ()
   | Error error -> fail (KR.registry_entry_validation_error_to_string error));
  (match KR.wakeup_running_exact ~intent:KR.Reactive_signal captured with
   | KR.Exact_wake_signaled -> ()
   | KR.Exact_wake_missing
   | KR.Exact_wake_replaced
   | KR.Exact_wake_not_running _
   | KR.Exact_wake_lifecycle_denied _
   | KR.Exact_wake_lifecycle_reserved _ ->
     fail "same-lane immutable update changed exact ownership");
  check bool "same lane record update remains signalable" true
    (Atomic.get captured.fiber_wakeup);
  Atomic.set captured.fiber_wakeup false;
  let replacement = register "exact-owner" in
  Atomic.set replacement.fiber_wakeup false;
  Atomic.set peer.fiber_wakeup false;
  (match KR.wakeup_running_exact ~intent:KR.Reactive_signal captured with
   | KR.Exact_wake_replaced -> ()
   | KR.Exact_wake_signaled
   | KR.Exact_wake_missing
   | KR.Exact_wake_not_running _
   | KR.Exact_wake_lifecycle_denied _
   | KR.Exact_wake_lifecycle_reserved _ ->
     fail "stale exact owner did not report replacement");
  check bool "replaced captured lane is not signaled" false
    (Atomic.get captured.fiber_wakeup);
  check bool "replacement lane is not signaled" false
    (Atomic.get replacement.fiber_wakeup);
  check bool "peer remains untouched after replacement" false
    (Atomic.get peer.fiber_wakeup)
;;

let test_wakeup_running_exact_reports_deferred_outcomes () =
  KR.For_testing.clear ();
  let removed = register "exact-missing" in
  KR.For_testing.clear ();
  (match KR.wakeup_running_exact ~intent:KR.Reactive_signal removed with
   | KR.Exact_wake_missing -> ()
   | KR.Exact_wake_signaled
   | KR.Exact_wake_replaced
   | KR.Exact_wake_not_running _
   | KR.Exact_wake_lifecycle_denied _
   | KR.Exact_wake_lifecycle_reserved _ ->
     fail "removed exact owner did not report missing");
  let offline_meta = make_meta "exact-offline" in
  let offline = KR.register_offline ~base_path offline_meta.name offline_meta in
  (match KR.wakeup_running_exact ~intent:KR.Reactive_signal offline with
   | KR.Exact_wake_not_running phase ->
     check string "exact deferred phase" "offline" (KSM.phase_to_string phase)
   | KR.Exact_wake_signaled
   | KR.Exact_wake_missing
   | KR.Exact_wake_replaced
   | KR.Exact_wake_lifecycle_denied _
   | KR.Exact_wake_lifecycle_reserved _ ->
     fail "offline exact owner did not report phase");
  let paused_meta = { (make_meta "exact-paused") with paused = true } in
  let paused = KR.For_testing.register ~base_path paused_meta.name paused_meta in
  (match KR.wakeup_running_exact ~intent:KR.Reactive_signal paused with
   | KR.Exact_wake_lifecycle_denied
       (Keeper_lifecycle_admission.Autonomous_paused _) -> ()
   | KR.Exact_wake_signaled
   | KR.Exact_wake_missing
   | KR.Exact_wake_replaced
   | KR.Exact_wake_not_running _
   | KR.Exact_wake_lifecycle_denied
       Keeper_lifecycle_admission.Autonomous_dead_tombstone
   | KR.Exact_wake_lifecycle_reserved _ ->
     fail "paused exact owner did not report lifecycle denial")
;;

let test_wakeup_running_exact_respects_lifecycle_owner_and_replacement () =
  KR.For_testing.clear ();
  let captured = register "exact-reserved" in
  Atomic.set captured.fiber_wakeup false;
  let token =
    match
      Reservation.acquire
        ~base_path
        ~keeper_name:captured.name
        ~expected_generation:captured.meta.runtime.nonce
        ~purpose:Reservation.Dead_revival
    with
    | Ok token -> token
    | Error _ -> fail "exact wake test could not acquire lifecycle ownership"
  in
  let replacement =
    Fun.protect
      ~finally:(fun () -> ignore (Reservation.release token : Reservation.release_outcome))
      (fun () ->
         (match KR.wakeup_running_exact ~intent:KR.Supervisor_resume captured with
          | KR.Exact_wake_lifecycle_reserved owner ->
            check string "reservation owner is reported"
              (Reservation.owner_id token)
              owner.owner_id
          | KR.Exact_wake_signaled
          | KR.Exact_wake_missing
          | KR.Exact_wake_replaced
          | KR.Exact_wake_not_running _
          | KR.Exact_wake_lifecycle_denied _ ->
            fail "unowned exact wake crossed lifecycle ownership");
         check bool "reserved captured lane is not signaled" false
           (Atomic.get captured.fiber_wakeup);
         let replacement_meta = make_meta captured.name in
         let replacement =
           match
             KR.register_offline_if_admitted_for_lifecycle
               token
               ~base_path
               captured.name
               replacement_meta
           with
           | Ok replacement -> replacement
           | Error _ -> fail "lifecycle owner could not install replacement lane"
         in
         Atomic.set replacement.fiber_wakeup false;
         (match KR.wakeup_running_exact ~intent:KR.Supervisor_resume captured with
          | KR.Exact_wake_lifecycle_reserved _ -> ()
          | KR.Exact_wake_signaled
          | KR.Exact_wake_missing
          | KR.Exact_wake_replaced
          | KR.Exact_wake_not_running _
          | KR.Exact_wake_lifecycle_denied _ ->
            fail "exact wake observed an in-transaction replacement");
         check bool "in-transaction replacement is not signaled" false
           (Atomic.get replacement.fiber_wakeup);
         replacement)
  in
  Atomic.set replacement.fiber_wakeup false;
  (match KR.wakeup_running_exact ~intent:KR.Supervisor_resume captured with
   | KR.Exact_wake_replaced -> ()
   | KR.Exact_wake_signaled
   | KR.Exact_wake_missing
   | KR.Exact_wake_not_running _
   | KR.Exact_wake_lifecycle_denied _
   | KR.Exact_wake_lifecycle_reserved _ ->
     fail "post-transaction stale wake did not report replacement");
  check bool "stale lane stays unsignaled after replacement" false
    (Atomic.get captured.fiber_wakeup);
  check bool "replacement lane stays unsignaled" false
    (Atomic.get replacement.fiber_wakeup)
;;

let test_wakeup_denies_paused_and_dead_without_signaling () =
  KR.For_testing.clear ();
  let paused_meta = { (make_meta "paused-wakeup") with paused = true } in
  let paused_entry = KR.For_testing.register ~base_path paused_meta.name paused_meta in
  Atomic.set paused_entry.fiber_wakeup false;
  (match KR.wakeup_running ~intent:KR.Scheduled_signal ~base_path paused_meta.name with
   | KR.Deferred_lifecycle (Keeper_lifecycle_admission.Autonomous_paused _) -> ()
   | KR.Signaled
   | KR.Deferred_unregistered
   | KR.Deferred_not_running _
   | KR.Deferred_lifecycle Keeper_lifecycle_admission.Autonomous_dead_tombstone ->
     fail "paused wake was not lifecycle-deferred");
  check bool "paused wake flag remains false" false (Atomic.get paused_entry.fiber_wakeup);
  let meta =
    { (make_meta "dead-wakeup") with
      paused = true
    ; latched_reason = Some Keeper_latched_reason.Dead_tombstone
    }
  in
  let entry = KR.For_testing.register ~base_path meta.name meta in
  Atomic.set entry.fiber_wakeup false;
  (match KR.wakeup_running ~intent:KR.Scheduled_signal ~base_path meta.name with
   | KR.Deferred_lifecycle
       Keeper_lifecycle_admission.Autonomous_dead_tombstone -> ()
   | KR.Signaled
   | KR.Deferred_unregistered
   | KR.Deferred_not_running _
   | KR.Deferred_lifecycle (Keeper_lifecycle_admission.Autonomous_paused _) ->
     fail "dead tombstone wake was not lifecycle-deferred");
  check bool "dead tombstone wake flag remains false" false
    (Atomic.get entry.fiber_wakeup)
;;

let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
;;

let cleanup_dir path =
  let rec rm target =
    if Sys.file_exists target
    then
      if Sys.is_directory target
      then (
        Sys.readdir target |> Array.iter (fun name -> rm (Filename.concat target name));
        Unix.rmdir target)
      else Unix.unlink target
  in
  match rm path with
  | () -> ()
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let test_reactive_wakeup_defers_offline_lane_after_queue_commit () =
  let dir = temp_dir "registry_reactive_offline_wakeup" in
  Fun.protect
    ~finally:(fun () ->
      KR.For_testing.clear ();
      cleanup_dir dir)
    (fun () ->
       Eio_main.run @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       KR.For_testing.clear ();
       let meta = make_meta "reactive-offline" in
       let entry = KR.register_offline ~base_path:dir meta.name meta in
       let stimulus : Keeper_event_queue.stimulus =
         { post_id = "reactive-offline-stimulus"
         ; urgency = Keeper_event_queue.Normal
         ; arrived_at = 1.0
         ; payload = Keeper_event_queue.Bootstrap
         }
       in
       Atomic.set entry.fiber_wakeup false;
       Masc.Keeper_keepalive_signal.wakeup_keeper
         ~base_path:dir
         ~stimulus
         meta.name;
       check bool "offline reactive wake flag remains clear" false
         (Atomic.get entry.fiber_wakeup);
       match
         Masc.Keeper_registry_event_queue.snapshot ~base_path:dir meta.name
         |> Keeper_event_queue.to_list
       with
       | [ { post_id; payload = Keeper_event_queue.Bootstrap; _ } ] ->
         check string "reactive stimulus remains queued" stimulus.post_id post_id
       | _ -> fail "reactive stimulus was not retained in the offline lane")
;;

let test_goal_assignment_defers_offline_lane_after_queue_commit () =
  let dir = temp_dir "registry_goal_offline_wakeup" in
  Fun.protect
    ~finally:(fun () ->
      KR.For_testing.clear ();
      cleanup_dir dir)
    (fun () ->
       Eio_main.run @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       KR.For_testing.clear ();
       let config = Masc.Workspace.default_config dir in
       let meta = make_meta "goal-offline" in
       let entry =
         KR.register_offline ~base_path:config.base_path meta.name meta
       in
       Atomic.set entry.fiber_wakeup false;
       let added =
         Masc.Keeper_goal_assignment_wake.enqueue_goal_assigned_wakes
           ~config
           ~keeper_name:meta.name
           ~assigned_by:"test"
           ~old_ids:[]
           ~new_ids:[ "goal-offline-1" ]
           ()
       in
       check (list string) "new goal is reported" [ "goal-offline-1" ] added;
       check bool "offline goal wake flag remains clear" false
         (Atomic.get entry.fiber_wakeup);
       match
         Masc.Keeper_registry_event_queue.snapshot
           ~base_path:config.base_path
           meta.name
         |> Keeper_event_queue.to_list
       with
       | [ { payload = Keeper_event_queue.Goal_assigned assignment; _ } ] ->
         check string "queued goal id" "goal-offline-1" assignment.ga_goal_id;
         check string "queued assignment actor" "test" assignment.ga_assigned_by
       | _ -> fail "goal assignment was not retained in the offline lane")
;;

let test_goal_completion_failure_wakes_only_durable_owners_once () =
  let dir = temp_dir "registry_goal_completion_failure_wakeup" in
  Fun.protect
    ~finally:(fun () ->
      KR.For_testing.clear ();
      cleanup_dir dir)
    (fun () ->
       Eio_main.run
       @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       KR.For_testing.clear ();
       let config = Masc.Workspace.default_config dir in
       ignore (Masc.Workspace.init config ~agent_name:(Some "planner"));
       let goal, _ =
         match
           Goal_store.upsert_goal
             config
             ~title:"Prove completion recovery"
             ()
         with
         | Ok value -> value
         | Error detail -> fail detail
       in
       let owner =
         { (make_meta "goal-owner") with
           active_goal_ids = [ goal.id ]
         }
       in
       let owner_peer =
         { (make_meta "goal-owner-peer") with
           active_goal_ids = [ goal.id ]
         }
       in
       let unrelated =
         { (make_meta "unrelated-keeper") with
           active_goal_ids = [ "another-goal" ]
         }
       in
       (match Masc.Keeper_meta_store.write_meta config owner with
        | Ok () -> ()
        | Error detail -> fail detail);
       (match Masc.Keeper_meta_store.write_meta config owner_peer with
        | Ok () -> ()
        | Error detail -> fail detail);
       (match Masc.Keeper_meta_store.write_meta config unrelated with
        | Ok () -> ()
        | Error detail -> fail detail);
       let failed_goal =
         match
           Goal_store.update_goal
             config
             ~goal_id:goal.id
             (fun current ->
                { current with
                  last_review_note = Some "Missing production evidence"
                ; last_review_at = Some "2026-07-24T00:00:00Z"
                ; completion_review_failure =
                    Some Goal_store.Rejected
                })
         with
         | Ok value -> value
         | Error detail -> fail detail
       in
       let project () =
         Masc.Keeper_goal_completion_failure_wake.project
           ~config
           ~goal:failed_goal
           ~failure:Goal_store.Rejected
       in
       let startup_recovery =
         Masc.Keeper_goal_completion_failure_wake.reconcile_all ~config
       in
       check int "startup recovery examines durable failure" 1
         startup_recovery.examined;
       check int "startup recovery projects crash-gap wake" 1
         startup_recovery.projected;
       check (list string) "owned failure is not unowned" []
         startup_recovery.unowned;
       check int "startup recovery has no incomplete delivery" 0
         (List.length startup_recovery.incomplete);
       (match project () with
        | Masc.Keeper_goal_completion_failure_wake.Projected projection ->
          check
            (list string)
            "only exact Goal owners selected"
            [ owner.name; owner_peer.name ]
            projection.owner_names;
          check
            (list string)
            "startup projection deduplicates on direct retry"
            [ owner.name; owner_peer.name ]
            projection.already_present_owner_names
        | Masc.Keeper_goal_completion_failure_wake.Unowned ->
          fail "owned Goal was reported unowned"
        | Masc.Keeper_goal_completion_failure_wake.Incomplete
            { failure; _ } ->
          fail
            (Masc.Keeper_goal_completion_failure_wake.failure_to_string
               failure));
       let owner_snapshot () =
         Masc.Keeper_registry_event_queue.snapshot
           ~base_path:config.base_path
           owner.name
       in
       check int "owner has one durable wake" 1
         (Keeper_event_queue.length (owner_snapshot ()));
       check int "peer owner has one durable wake" 1
         (Masc.Keeper_registry_event_queue.snapshot
            ~base_path:config.base_path
            owner_peer.name
          |> Keeper_event_queue.length);
       check int "unrelated Keeper has no wake" 0
         (Masc.Keeper_registry_event_queue.snapshot
            ~base_path:config.base_path
            unrelated.name
          |> Keeper_event_queue.length);
       check int "repeat projection still one delivery" 1
         (Keeper_event_queue.length (owner_snapshot ()));
       KR.For_testing.clear ();
       check int "restart reload keeps one delivery" 1
         (Keeper_event_queue_persistence.load
            ~base_path:config.base_path
            ~keeper_name:owner.name
          |> Keeper_event_queue.length);
       let contains_text text needle =
         let text_len = String.length text in
         let needle_len = String.length needle in
         let rec loop index =
           index + needle_len <= text_len
           && (String.equal
                 (String.sub text index needle_len)
                 needle
               || loop (index + 1))
         in
         String.equal needle "" || loop 0
       in
       match Keeper_event_queue.to_list (owner_snapshot ()) with
       | [ ({ payload =
                Keeper_event_queue.Goal_completion_review_failed failure
            ; _
            } as stimulus) ] ->
         check string "wake goal id" goal.id failure.gcrf_goal_id;
         check
           string
           "wake contains durable review timestamp"
           "2026-07-24T00:00:00Z"
           failure.gcrf_reviewed_at;
         check int "wake fingerprint is SHA-256" 64
           (String.length failure.gcrf_review_fingerprint);
         (match
            Masc.Keeper_world_observation.pending_board_event_of_stimulus
              ~meta:owner
              stimulus
          with
          | Ok (Some event) ->
            check bool "wake is actionable turn input" true
              (contains_text event.preview "submit a new completion claim");
            check bool "raw reviewer reason is not auto-injected" false
              (contains_text event.preview "Missing production evidence");
            ignore
              (KR.For_testing.register
                 ~base_path:config.base_path
                 owner.name
                 owner);
            let lease =
              match
                Masc.Keeper_registry_event_queue.claim_when_result
                  ~base_path:config.base_path
                  owner.name
                  ~claimed_at:1.0
                  ~ready:(fun _ -> true)
              with
              | Ok (Some lease) -> lease
              | Ok None -> fail "owner completion wake was not claimable"
              | Error detail -> fail detail
            in
            Masc.Keeper_reaction_ledger.record_event_queue_turn_started
              ~base_path:config.base_path
              ~keeper_name:owner.name
              stimulus;
            (match
               Masc.Keeper_registry_event_queue.settle_result
                 ~base_path:config.base_path
                 owner.name
                 ~settled_at:2.0
                 ~lease
                 ~settlement:Masc.Keeper_registry_event_queue.Ack
             with
             | Ok
                 (Masc.Keeper_registry_event_queue.Settled _
                 | Masc.Keeper_registry_event_queue.Already_settled _) ->
               ()
             | Ok
                 (Masc.Keeper_registry_event_queue.Committed_followup_failed
                    { detail; _ }) ->
               fail detail
             | Error detail -> fail detail);
            (match
               Masc.Keeper_reaction_ledger
               .project_event_queue_transition_outbox_result
                 ~base_path:config.base_path
                 ~keeper_name:owner.name
             with
             | Ok () -> ()
             | Error detail -> fail detail);
            let after_delivery_recovery =
              Masc.Keeper_goal_completion_failure_wake.reconcile_all
                ~config
            in
            check int "delivered failure remains reconciled" 1
              after_delivery_recovery.projected;
            check int "delivered failure is not re-enqueued" 0
              (Keeper_event_queue.length (owner_snapshot ()));
            check int "undelivered peer remains pending" 1
              (Masc.Keeper_registry_event_queue.snapshot
                 ~base_path:config.base_path
                 owner_peer.name
               |> Keeper_event_queue.length)
          | Ok None -> fail "Goal completion failure wake rendered empty"
          | Error _ -> fail "Goal completion failure wake required Board I/O")
       | _ -> fail "restart changed Goal completion failure wake")
;;

let test_goal_completion_failure_reports_unowned () =
  let dir = temp_dir "registry_goal_completion_failure_unowned" in
  Fun.protect
    ~finally:(fun () ->
      KR.For_testing.clear ();
      cleanup_dir dir)
    (fun () ->
       Eio_main.run
       @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       let config = Masc.Workspace.default_config dir in
       ignore (Masc.Workspace.init config ~agent_name:(Some "planner"));
       let goal, _ =
         match Goal_store.upsert_goal config ~title:"Unowned Goal" () with
         | Ok value -> value
         | Error detail -> fail detail
       in
       let failed_goal =
         match
           Goal_store.update_goal
             config
             ~goal_id:goal.id
             (fun current ->
                { current with
                  last_review_note = Some "Reviewer unavailable"
                ; last_review_at = Some "2026-07-24T00:00:00Z"
                ; completion_review_failure =
                    Some Goal_store.Unavailable
                })
         with
         | Ok value -> value
         | Error detail -> fail detail
       in
       (match
          Masc.Keeper_goal_completion_failure_wake.project
            ~config
            ~goal:failed_goal
            ~failure:Goal_store.Unavailable
        with
        | Masc.Keeper_goal_completion_failure_wake.Unowned -> ()
        | Masc.Keeper_goal_completion_failure_wake.Projected _ ->
          fail "unowned Goal produced a synthetic owner wake"
        | Masc.Keeper_goal_completion_failure_wake.Incomplete
            { failure; _ } ->
          fail
            (Masc.Keeper_goal_completion_failure_wake.failure_to_string
               failure));
       let later_owner =
         { (make_meta "later-goal-owner") with
           active_goal_ids = [ goal.id ]
         }
       in
       (match Masc.Keeper_meta_store.write_meta config later_owner with
        | Ok () -> ()
        | Error detail -> fail detail);
       let owner_runtime_dir =
         Filename.concat
           (Common.keepers_runtime_dir_of_base ~base_path:config.base_path)
           later_owner.name
       in
       Workspace_utils.mkdir_p owner_runtime_dir;
       let queue_path =
         Filename.concat owner_runtime_dir "event-queue.json"
       in
       Unix.mkdir queue_path 0o755;
       let storage_blocked =
         Masc.Keeper_goal_completion_failure_wake.reconcile_all ~config
       in
       (match storage_blocked.incomplete with
        | [ (goal_id, Masc.Keeper_goal_completion_failure_wake.Delivery_failed
                        [ (keeper_name, _) ]) ] ->
          check string "storage failure keeps exact Goal identity" goal.id goal_id;
          check string "storage failure keeps exact owner identity"
            later_owner.name keeper_name
        | _ -> fail "durable enqueue failure was not returned as typed incomplete");
       Unix.rmdir queue_path;
       let recovered =
         Masc.Keeper_goal_completion_failure_wake.reconcile_all ~config
       in
       check int "later owner assignment becomes projectable" 1
         recovered.projected;
       check
         int
         "later owner receives the durable failed-review wake"
         1
         (Masc.Keeper_registry_event_queue.snapshot
            ~base_path:config.base_path
            later_owner.name
          |> Keeper_event_queue.length))
;;

let contains_substring text needle =
  let text_len = String.length text in
  let needle_len = String.length needle in
  let rec loop idx =
    idx + needle_len <= text_len
    && (String.sub text idx needle_len = needle || loop (idx + 1))
  in
  needle_len = 0 || loop 0
;;

let test_tool_dispatch_preserves_exact_meta_after_replacement () =
  let dir = temp_dir "registry_exact_turn_meta" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
       Eio_main.run @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       let config = Masc.Workspace.default_config dir in
       let meta =
         { (make_meta "fallback-keeper") with
           allowed_paths = [ config.base_path ]
         }
       in
       let evidence = "exact-turn-meta-evidence" in
       let evidence_path = Filename.concat config.base_path "exact-meta.txt" in
       Out_channel.with_open_bin evidence_path (fun channel ->
         Out_channel.output_string channel evidence);
       let ctx_work =
         Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"test"
       in
       let _original_entry =
         KR.For_testing.register ~base_path:config.base_path meta.name meta
       in
       Fun.protect
         ~finally:(fun () -> KR.For_testing.unregister ~base_path:config.base_path meta.name)
         (fun () ->
            let provider_reads = Atomic.make 0 in
            let provider () =
              Atomic.incr provider_reads;
              Masc.Keeper_publication_recovery_availability.Non_runtime
            in
            let exact_resources =
              match
                Masc.Keeper_publication_recovery_scope.resolve_turn_resources
                  ~provider
                  ~base_path:config.base_path
                  ~keeper_name:meta.name
              with
              | Ok resources -> resources
              | Error failure ->
                fail
                  (Masc.Keeper_publication_recovery_scope.failure_to_string
                     failure)
            in
            let replacement_meta =
              { meta with
                allowed_paths = [ Filename.concat config.base_path "other" ]
              }
            in
            let replacement =
              KR.For_testing.register
                ~base_path:config.base_path
                replacement_meta.name
                replacement_meta
            in
            (match KR.get_with_health ~base_path:config.base_path meta.name with
             | Some (current, KR.Healthy) ->
               check bool "healthy replacement installed" true (current == replacement)
             | Some (_, health) ->
               fail
                 ("replacement is unhealthy: "
                  ^ KR.registry_entry_validation_error_to_string health)
             | None -> fail "replacement entry not found");
            let result =
              KET.execute_keeper_tool_call_with_outcome
                ~config
                ~meta:exact_resources.entry.meta
                ~publication_recovery:exact_resources.publication_recovery
                ~ctx_work
                ~name:"Read"
                ~input:(`Assoc [ ("file_path", `String evidence_path) ])
                ()
            in
            (match result.disposition with
             | Tool_result.Completed () -> ()
             | Tool_result.Deferred () ->
               failf
                 "exact admitted meta dispatch was unexpectedly deferred: %s"
                 result.raw_output
             | Tool_result.Failed failure_class ->
               failf
                 "exact admitted meta dispatch failed (%s): %s"
                 (Tool_result.tool_failure_class_to_string failure_class)
                 result.raw_output);
            let content =
              Yojson.Safe.from_string result.raw_output
              |> Yojson.Safe.Util.member "content"
              |> Yojson.Safe.Util.to_string
            in
            check
              string
              "dispatch uses exact admitted meta, not same-name replacement meta"
              evidence
              content;
            check int "read path never reads recovery provider" 0
              (Atomic.get provider_reads)))
;;

let () =
  run
    "keeper_registry_hardening"
    [ ( "put_entry"
      , [ test_case "rejects meta name mismatch" `Quick test_put_entry_rejects_meta_name_mismatch ]
      )
    ; ( "update_entry"
      , [ test_case
            "rejects corrupted closure result and preserves original"
            `Quick
            test_update_entry_rejects_corrupted_result
        ; test_case
            "exact update preserves replacement lane"
            `Quick
            test_update_entry_exact_preserves_replacement_lane
        ] )
    ; ( "unregister_exact"
      , [ test_case
            "stale entry preserves replacement lane"
            `Quick
            test_unregister_exact_preserves_replacement_lane
        ; test_case
            "same lane immutable update remains removable"
            `Quick
            test_unregister_exact_accepts_same_lane_record_update
        ] )
    ; ( "dispatch_event"
      , [ test_case
            "skips phase side effects when validated write fails"
            `Quick
            test_dispatch_write_failure_skips_phase_side_effects
        ; test_case
            "exact dispatch preserves replacement lane"
            `Quick
            test_dispatch_event_exact_preserves_replacement_lane
        ] )
    ; ( "keeper_lane"
      , [ test_case
            "rejects fork on an already-cancelling switch"
            `Quick
            test_lane_fork_rejects_cancelling_switch
        ] )
    ; ( "get_with_health"
      , [ test_case "get filters corrupted entry" `Quick test_get_filters_corrupted_entry ] )
    ; ( "wakeup"
      , [ test_case
            "reports signaled and deferred outcomes"
            `Quick
            test_wakeup_running_reports_typed_outcome
        ; test_case
            "paused and dead keepers never receive runnable signal"
            `Quick
            test_wakeup_denies_paused_and_dead_without_signaling
        ; test_case
            "exact wake signals only the captured owner lane"
            `Quick
            test_wakeup_running_exact_preserves_owner_lane
        ; test_case
            "exact wake reports missing, phase, and lifecycle outcomes"
            `Quick
            test_wakeup_running_exact_reports_deferred_outcomes
        ; test_case
            "exact wake serializes lifecycle ownership and replacement"
            `Quick
            test_wakeup_running_exact_respects_lifecycle_owner_and_replacement
        ] )
    ; ( "wakeup_callers"
      , [ test_case
            "reactive stimulus persists while offline wake is deferred"
            `Quick
            test_reactive_wakeup_defers_offline_lane_after_queue_commit
        ; test_case
            "goal assignment persists while offline wake is deferred"
            `Quick
            test_goal_assignment_defers_offline_lane_after_queue_commit
        ; test_case
            "Goal completion failure wakes only durable owners once"
            `Quick
            test_goal_completion_failure_wakes_only_durable_owners_once
        ; test_case
            "Goal completion failure reports unowned"
            `Quick
            test_goal_completion_failure_reports_unowned
        ] )
    ; ( "tool_dispatch_exact_resources"
      , [ test_case "preserves exact meta after healthy entry replacement" `Quick
            test_tool_dispatch_preserves_exact_meta_after_replacement
        ] )
    ]
;;
