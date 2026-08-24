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

let registry_snapshot ~base_path keeper_name =
  match Masc.Keeper_registry_event_queue.snapshot_result ~base_path keeper_name with
  | Ok queue -> queue
  | Error detail -> fail detail
;;

let make_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("trace_id", `String ("trace-" ^ name));
          ("allowed_paths", `List [ `String "*" ]);
          ("autoboot_enabled", `Bool false);
        ])
  with
  | Ok m -> m
  | Error e -> failwith ("make_meta failed: " ^ e)
;;

let make_goal_reconciler_meta () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String "goal-reconciler"
        ; "agent_name", `String "keeper-goal-reconciler-agent"
        ; "trace_id", `String "trace-goal-reconciler"
        ; "allowed_paths", `List [ `String "*" ]
        ; "autoboot_enabled", `Bool false
        ])
  with
  | Ok meta -> meta
  | Error detail -> failwith ("goal reconciler meta failed: " ^ detail)
;;

let write_text_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)
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
          runtime =
            { entry.meta.runtime with
              usage = { entry.meta.runtime.usage with total_turns = -1 }
            }
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
    check string "missing field" "usage.total_turns" field;
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
        ~purpose:Reservation.Paused_work_disposition
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

let test_tool_usage_restore_uses_lifecycle_authority () =
  let dir = temp_dir "registry_tool_usage_restore" in
  Fun.protect
    ~finally:(fun () ->
      KR.For_testing.clear ();
      cleanup_dir dir)
    (fun () ->
       Eio_main.run @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       KR.For_testing.clear ();
       let meta = make_meta "lifecycle-restore" in
       let registered = KR.For_testing.register ~base_path:dir meta.name meta in
       let path =
         Filename.concat
           dir
           ".masc/keepers/tool_usage/lifecycle-restore.json"
       in
       Fs_compat.mkdir_p (Filename.dirname path);
       Fs_compat.save_file
         path
         (Yojson.Safe.to_string
            (`Assoc
              [ "schema_version", `Int 2
              ; "keeper", `String meta.name
              ; "flushed_at", `Float 1.0
              ; ( "tools"
                , `List
                    [ `Assoc
                        [ "tool", `String "masc_status"
                        ; "count", `Int 1
                        ; "successes", `Int 1
                        ; "deferred", `Int 0
                        ; "failures", `Int 0
                        ; "last_used_at", `Float 1.0
                        ]
                    ] )
              ])
          ^ "\n");
       let token =
         match
           Reservation.acquire
             ~base_path:dir
             ~keeper_name:meta.name
             ~purpose:Reservation.Keepalive_launch
         with
         | Ok token -> token
         | Error _ -> fail "failed to reserve Keeper launch lifecycle"
       in
       Fun.protect
         ~finally:(fun () ->
           ignore (Reservation.release token : Reservation.release_outcome))
         (fun () ->
            Masc.Keeper_registry_tool_usage_persistence.restore
              ~base_path:dir
              meta.name;
            check (list string) "name-only restore is fenced" []
              (KR.tool_usage_of ~base_path:dir meta.name |> List.map fst);
            Masc.Keeper_registry_tool_usage_persistence.restore_for_lifecycle
              token
              registered;
            check (option int) "token-qualified restore keeps exact count" (Some 1)
              (KR.tool_usage_of ~base_path:dir meta.name
               |> List.assoc_opt "masc_status"
               |> Option.map (fun entry -> entry.Keeper_types.count))))
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
         registry_snapshot ~base_path:dir meta.name
         |> Keeper_event_queue.to_list
       with
       | [ { post_id; payload = Keeper_event_queue.Bootstrap; _ } ] ->
         check string "reactive stimulus remains queued" stimulus.post_id post_id
       | _ -> fail "reactive stimulus was not retained in the offline lane")
;;

let test_terminal_hook_degradation_does_not_invalidate_task_commit () =
  let dir = temp_dir "registry_terminal_hook_degradation" in
  let previous_hook = Atomic.get Workspace_hooks.task_terminal_committed_fn in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Workspace_hooks.task_terminal_committed_fn previous_hook;
      cleanup_dir dir)
    (fun () ->
       Eio_main.run @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       let config = Masc.Workspace.default_config dir in
       ignore (Masc.Workspace.init config ~agent_name:(Some "external"));
       let terminal_with hook title =
         Atomic.set Workspace_hooks.task_terminal_committed_fn hook;
         ignore
           (Workspace_task.add_task
              config
              ~title
              ~priority:2
              ~description:"");
         let task_id =
           match
             Masc.Workspace.get_tasks_raw config
             |> List.find_opt (fun (task : Masc_domain.task) ->
                  String.equal task.title title)
           with
           | Some task -> task.id
           | None -> fail "newly added hook-degradation Task was not persisted"
         in
         let transition action =
           Masc.Workspace.transition_task_r
             config
             ~agent_name:"external"
             ~task_id
             ~action
             ()
         in
         (match transition Masc_domain.Claim with
          | Ok _ -> ()
          | Error error -> fail (Masc_domain.masc_error_to_string error));
         (match transition Masc_domain.Start with
          | Ok _ -> ()
          | Error error -> fail (Masc_domain.masc_error_to_string error));
         (match transition Masc_domain.Cancel with
          | Ok _ ->
            (match
               Masc.Workspace.get_tasks_raw config
               |> List.find_opt (fun (task : Masc_domain.task) ->
                    String.equal task.id task_id)
             with
             | Some task
               when Masc_domain.task_status_is_terminal task.task_status ->
               ()
             | Some _ | None ->
               fail "terminal hook degradation lost terminal state")
          | Error error ->
            fail
              ("committed terminal transition was reported as failure: "
               ^ Masc_domain.masc_error_to_string error))
       in
       terminal_with
         (fun _config ~agent_name:_ ~task_id:_ ->
            Workspace_hooks.Task_terminal_delivery_degraded
              { kind = "injected"; detail = "delivery unavailable" })
         "typed delivery degradation";
       terminal_with
         (fun _config ~agent_name:_ ~task_id:_ ->
            failwith "injected hook exception")
         "hook exception";
       let cancellation_title = "hook cancellation" in
       ignore
         (Workspace_task.add_task
            config
            ~title:cancellation_title
            ~priority:2
            ~description:"");
       let cancellation_task =
         Masc.Workspace.get_tasks_raw config
         |> List.find (fun (task : Masc_domain.task) ->
              String.equal task.title cancellation_title)
       in
       let transition action =
         Masc.Workspace.transition_task_r
           config
           ~agent_name:"external"
           ~task_id:cancellation_task.id
           ~action
           ()
       in
       (match transition Masc_domain.Claim with
        | Ok _ -> ()
        | Error error -> fail (Masc_domain.masc_error_to_string error));
       (match transition Masc_domain.Start with
        | Ok _ -> ()
        | Error error -> fail (Masc_domain.masc_error_to_string error));
       Atomic.set Workspace_hooks.task_terminal_committed_fn
         (fun _config ~agent_name:_ ~task_id:_ ->
            raise
              (Eio.Cancel.Cancelled
                 (Failure "injected post-commit cancellation")));
       let cancellation_propagated =
         try
           ignore (transition Masc_domain.Cancel);
           false
         with
         | Eio.Cancel.Cancelled _ -> true
       in
       check bool "post-commit cancellation is re-raised" true cancellation_propagated;
       match
         Masc.Workspace.get_tasks_raw config
         |> List.find_opt (fun (task : Masc_domain.task) ->
              String.equal task.id cancellation_task.id)
       with
       | Some task when Masc_domain.task_status_is_terminal task.task_status -> ()
       | Some _ | None -> fail "cancellation propagation invalidated committed Task")
;;

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
    ; ( "tool_usage_restore"
      , [ test_case
            "uses exact lifecycle authority"
            `Quick
            test_tool_usage_restore_uses_lifecycle_authority
        ] )
    ; ( "get_with_health"
      , [ test_case "get filters corrupted entry" `Quick test_get_filters_corrupted_entry ] )
    ; ( "wakeup"
      , [ test_case
            "reports signaled and deferred outcomes"
            `Quick
            test_wakeup_running_reports_typed_outcome
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
            "terminal hook degradation preserves committed Task outcome"
            `Quick
            test_terminal_hook_degradation_does_not_invalidate_task_commit
        ] )
    ; ( "tool_dispatch_exact_resources"
      , [ test_case "preserves exact meta after healthy entry replacement" `Quick
            test_tool_dispatch_preserves_exact_meta_after_replacement
        ] )
    ]
;;
