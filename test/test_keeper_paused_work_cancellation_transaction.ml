open Masc

module Queue = Keeper_event_queue
module Persistence = Keeper_event_queue_persistence
module Registry_queue = Keeper_registry_event_queue
module State = Keeper_event_queue_state
module Transaction = Keeper_paused_work_cancellation_transaction
module Disposition_receipt = Keeper_paused_work_disposition_receipt
module Resume_transaction = Keeper_paused_work_resume_transaction

let require_ok label = function
  | Ok value -> value
  | Error detail -> Alcotest.failf "%s: %s" label detail
;;

let require_some label = function
  | Some value -> value
  | None -> Alcotest.failf "%s: expected Some" label
;;

let rec remove_tree path =
  if Sys.file_exists path
  then if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_seeded_owner ?(registered = true) ?latched_reason ~paused f =
  let base_path = Filename.temp_dir "keeper-paused-cancel-transaction" "" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.For_testing.clear ();
      remove_tree base_path)
    (fun () ->
       Eio_main.run @@ fun env ->
       if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
       Eio.Switch.run @@ fun sw ->
       let config = Workspace.default_config base_path in
       ignore (Workspace.init config ~agent_name:(Some "operator"));
       let keeper_name = "paused-cancel-owner" in
       let meta =
         Masc_test_deps.meta_of_json_fixture
           (`Assoc
              [ "name", `String keeper_name
              ; "trace_id", `String "trace-paused-cancel-owner"
              ; "autoboot_enabled", `Bool false
              ])
         |> require_ok "parse Keeper metadata fixture"
       in
       let meta =
         { meta with
           paused
         ; latched_reason
         }
       in
       Keeper_meta_store.replace_snapshot config meta |> require_ok "persist Keeper metadata";
       let persisted =
         Keeper_meta_store.read_meta config keeper_name
         |> require_ok "read persisted Keeper metadata"
         |> require_some "persisted Keeper metadata"
       in
       (match Keeper_owner_registry.install_from_store ~sw ~operation_runner:None ~on_turn_slot_released:None config with
        | Ok count -> Alcotest.(check int) "installed owner count" 1 count
        | Error error ->
          Alcotest.fail
            (Keeper_owner_registry.install_error_to_string error));
       let source : Queue.stimulus =
         { post_id = "accepted-source"
         ; urgency = Queue.Normal
         ; arrived_at = 1.0
         ; payload = Queue.Bootstrap
         }
       in
       Persistence.update_result ~base_path ~keeper_name (fun pending ->
         Queue.enqueue pending source)
       |> require_ok "seed accepted source";
       if registered
       then (
         ignore (Keeper_registry.For_testing.register ~base_path keeper_name persisted);
         if paused
         then
           match
             Keeper_registry.dispatch_event
               ~base_path
               keeper_name
               Keeper_state_machine.Operator_pause
           with
           | Ok _ -> ()
           | Error error ->
             Alcotest.failf
               "pause live Keeper owner: %s"
               (Keeper_state_machine.transition_error_to_string error));
       f config keeper_name source)
;;

let with_pending_lane ?registered ?latched_reason ~paused f =
  with_seeded_owner
    ?registered
    ?latched_reason
    ~paused
    (fun config keeper_name source ->
       let source_incarnation =
         Persistence.load_state_result
           ~base_path:config.Workspace.base_path
           ~keeper_name
         |> require_ok "load pending accepted source incarnation"
         |> State.select_when
              ~now:(Unix.gettimeofday ())
              ~ready:(Queue.stimulus_identity_equal source)
         |> require_some "select pending accepted source"
         |> fun selection -> selection.admitted_revision
       in
       let request : Transaction.pending_request =
         { source
         ; source_incarnation
         ; operator_operation_id = "operator-pending-cancel-1"
         ; reason = "operator rejected exact pending paused work"
         }
       in
       f config keeper_name request)
;;

let check_released = function
  | Some Keeper_lifecycle_reservation.Released -> ()
  | Some Keeper_lifecycle_reservation.Release_missing ->
    Alcotest.fail "lifecycle reservation disappeared before release"
  | Some (Keeper_lifecycle_reservation.Release_not_owner owner) ->
    Alcotest.failf
      "lifecycle reservation owner changed: %s"
      (Keeper_lifecycle_reservation.snapshot_to_string owner)
  | None -> Alcotest.fail "new cancellation did not acquire a lifecycle reservation"
;;

let check_replayed_without_reservation = function
  | None -> ()
  | Some release ->
    Alcotest.failf
      "committed replay acquired a lifecycle reservation: %s"
      (match release with
       | Keeper_lifecycle_reservation.Released -> "released"
       | Keeper_lifecycle_reservation.Release_missing -> "release_missing"
       | Keeper_lifecycle_reservation.Release_not_owner owner ->
         "release_not_owner: " ^ Keeper_lifecycle_reservation.snapshot_to_string owner)
;;

let check_resume_released = function
  | Keeper_lifecycle_reservation.Released -> ()
  | Keeper_lifecycle_reservation.Release_missing ->
    Alcotest.fail "Resume_owner lifecycle reservation disappeared before release"
  | Keeper_lifecycle_reservation.Release_not_owner owner ->
    Alcotest.failf
      "Resume_owner lifecycle reservation owner changed: %s"
      (Keeper_lifecycle_reservation.snapshot_to_string owner)
;;

let test_pending_cancellation_commits_exact_remove () =
  with_pending_lane
    ~registered:false
    ~paused:true
    (fun config keeper_name request ->
       let first =
         Transaction.cancel_pending config ~keeper_name request
         |> Result.map_error Transaction.error_to_string
         |> require_ok "cancel pending paused work"
       in
       check_released first.reservation_release;
       (match first.transition with
        | Registry_queue.Transition_applied _
        | Registry_queue.Transition_committed_followup_failed _ -> ()
        | Registry_queue.Transition_already_applied _ ->
          Alcotest.fail "first pending cancellation was already applied");
       let state =
         Persistence.load_state_result
           ~base_path:config.Workspace.base_path
           ~keeper_name
         |> require_ok "load pending cancellation result"
       in
       Alcotest.(check int)
         "exact pending source removed"
         0
         (Queue.length (State.pending state)))
;;

let test_pending_cancellation_busy_has_zero_mutation () =
  with_pending_lane
    ~registered:false
    ~paused:true
    (fun config keeper_name request ->
       let base_path = config.Workspace.base_path in
       (match
          Keeper_owner_registry.run_maintenance_if_idle
            ~base_path
            ~keeper_name
            (fun () -> Transaction.cancel_pending config ~keeper_name request)
        with
        | Ok (`Ran (Error (Transaction.Admission_busy _))) -> ()
        | Ok (`Ran (Error error)) ->
          Alcotest.fail (Transaction.error_to_string error)
        | Error error ->
          Alcotest.fail (Keeper_owner_registry.command_error_to_string error)
        | Ok (`Ran (Ok _) | `Busy _) ->
          Alcotest.fail "pending cancellation was not deferred by Keeper Owner");
       let state =
         Persistence.load_state_result ~base_path ~keeper_name
         |> require_ok "load admission-busy cancellation lane"
       in
       Alcotest.(check int)
         "admission busy retains pending source"
         1
         (Queue.length (State.pending state)))
;;

let test_unrelated_enqueue_preserves_pending_incarnation () =
  with_pending_lane
    ~registered:false
    ~paused:true
    (fun config keeper_name request ->
       let unrelated : Queue.stimulus =
         { post_id = "unrelated-cancellation-source"
         ; urgency = Queue.Low
         ; arrived_at = 2.0
         ; payload = Queue.Bootstrap
         }
       in
       Persistence.update_result
         ~base_path:config.Workspace.base_path
         ~keeper_name
         (fun pending -> Queue.enqueue pending unrelated)
       |> require_ok "enqueue unrelated cancellation source";
       let result =
         Transaction.cancel_pending config ~keeper_name request
         |> Result.map_error Transaction.error_to_string
         |> require_ok "cancel selected source after unrelated enqueue"
       in
       (match result.transition with
        | Registry_queue.Transition_applied _
        | Registry_queue.Transition_committed_followup_failed _ -> ()
        | Registry_queue.Transition_already_applied _ ->
          Alcotest.fail "unrelated enqueue replayed pending cancellation");
       let state =
         Persistence.load_state_result
           ~base_path:config.Workspace.base_path
           ~keeper_name
         |> require_ok "load cancellation result after unrelated enqueue"
       in
       Alcotest.(check int)
         "only unrelated source remains"
         1
         (Queue.length (State.pending state));
       Alcotest.(check bool)
         "unrelated cancellation source is preserved"
         true
         (State.pending state
          |> Queue.to_list
          |> List.exists (Queue.stimulus_identity_equal unrelated)))
;;

let test_reinserted_source_rejects_old_pending_incarnation () =
  with_pending_lane
    ~registered:false
    ~paused:true
    (fun config keeper_name request ->
       let base_path = config.Workspace.base_path in
       let old_selection : State.pending_selection =
         { source = request.source
         ; admitted_revision = request.source_incarnation
         ; checkpoint_retentions = 0
         }
       in
       Persistence.ack_pending_result
         ~base_path
         ~keeper_name
         ~selection:old_selection
         ()
       |> require_ok "remove old cancellation source incarnation";
       Persistence.update_result ~base_path ~keeper_name (fun pending ->
         Queue.enqueue pending request.source)
       |> require_ok "reinsert cancellation source";
       (match Transaction.cancel_pending config ~keeper_name request with
        | Error
            (Transaction.Failed
               { cause = Transaction.Queue_commit_failed _; _ }) ->
          ()
        | Error error -> Alcotest.fail (Transaction.error_to_string error)
        | Ok _ ->
          Alcotest.fail "old cancellation incarnation removed the reinserted source");
       let state =
         Persistence.load_state_result ~base_path ~keeper_name
         |> require_ok "load reinserted cancellation source"
       in
       Alcotest.(check int)
         "reinserted cancellation source remains"
         1
         (Queue.length (State.pending state)))
;;

let resume_request operation_id : Resume_transaction.request =
  { operator_operation_id = operation_id }
;;

let test_resume_owner_commits_receipt_and_preserves_pending () =
  with_seeded_owner ~paused:true (fun config keeper_name source ->
    let request = resume_request "operator-resume-1" in
    let first =
      Resume_transaction.resume config ~keeper_name request
      |> Result.map_error Resume_transaction.error_to_string
      |> require_ok "commit Resume_owner"
    in
    check_resume_released first.reservation_release;
    (match first.commit_status with
     | Resume_transaction.Committed -> ()
     | Resume_transaction.Already_committed ->
       Alcotest.fail "first Resume_owner call replayed an existing receipt");
    (match first.projection with
     | Resume_transaction.Applied phase ->
       Alcotest.(check bool)
         "Resume_owner leaves paused phase"
         false
         (phase = Keeper_state_machine.Paused)
     | Resume_transaction.Committed_followup_failed failure ->
       Alcotest.fail
         (Resume_transaction.error_to_string
            { cause = failure; reservation_release = None }));
    let durable =
      Keeper_meta_store.read_meta config keeper_name
      |> require_ok "read resumed durable owner"
      |> require_some "resumed durable owner"
    in
    Alcotest.(check bool) "durable pause cleared" false durable.paused;
    let registered =
      Keeper_registry.get ~base_path:config.Workspace.base_path keeper_name
      |> require_some "resumed registry owner"
    in
    Alcotest.(check bool) "registry pause cleared" false registered.meta.paused;
    let queue_state =
      Persistence.load_state_result
        ~base_path:config.Workspace.base_path
        ~keeper_name
      |> require_ok "load resumed pending queue"
    in
    Alcotest.(check bool)
      "Resume_owner preserves exact pending work"
      true
      (Queue.to_list (State.pending queue_state) = [ source ]);
    let stored =
      Disposition_receipt.load
        config
        ~keeper_name
        ~operator_operation_id:request.operator_operation_id
      |> require_ok "load Resume_owner receipt"
      |> require_some "Resume_owner receipt"
    in
    Alcotest.(check bool)
      "returned receipt is the durable receipt"
      true
      (Disposition_receipt.equal first.receipt stored);
    let replay =
      Resume_transaction.resume config ~keeper_name request
      |> Result.map_error Resume_transaction.error_to_string
      |> require_ok "replay Resume_owner"
    in
    check_resume_released replay.reservation_release;
    (match replay.projection with
     | Resume_transaction.Applied _ -> ()
     | Resume_transaction.Committed_followup_failed failure ->
       Alcotest.fail
         (Resume_transaction.error_to_string
            { cause = failure; reservation_release = None }));
    (match replay.commit_status with
     | Resume_transaction.Already_committed -> ()
     | Resume_transaction.Committed ->
       Alcotest.fail "Resume_owner replay created a second receipt");
    let second_operation = resume_request "operator-resume-2" in
    (match Resume_transaction.resume config ~keeper_name second_operation with
     | Error
         { Resume_transaction.cause = Resume_transaction.Durable_owner_not_paused
         ; _
         } -> ()
     | Error error -> Alcotest.fail (Resume_transaction.error_to_string error)
     | Ok _ -> Alcotest.fail "active owner accepted a second Resume_owner receipt");
    match
      Disposition_receipt.load
        config
        ~keeper_name
        ~operator_operation_id:second_operation.operator_operation_id
    with
    | Ok None -> ()
    | Ok (Some _) -> Alcotest.fail "active owner persisted a second Resume_owner receipt"
    | Error detail -> Alcotest.fail detail)
;;

let test_resume_owner_completes_prepared_receipt_projection () =
  with_seeded_owner ~paused:true (fun config keeper_name _source ->
    let request = resume_request "operator-resume-prepared" in
    let durable =
      Keeper_meta_store.read_meta config keeper_name
      |> require_ok "read prepared Resume_owner durable owner"
      |> require_some "prepared Resume_owner durable owner"
    in
    let prepared : Disposition_receipt.t =
      { keeper_name
      ; expected_trace_id = durable.runtime.trace_id
      ; operator_operation_id = request.operator_operation_id
      ; requested_at = 5.0
      ; operation = Disposition_receipt.Resume_owner
      }
    in
    (match
       Disposition_receipt.with_keeper_lock config ~keeper_name (fun lock ->
         Disposition_receipt.save_if_absent lock config prepared)
     with
     | Ok (Ok Disposition_receipt.Created) -> ()
     | Ok (Ok (Disposition_receipt.Existing _)) ->
       Alcotest.fail "prepared Resume_owner receipt already existed"
     | Ok (Error detail) | Error detail -> Alcotest.fail detail);
    Keeper_registry.For_testing.clear ();
    let interrupted =
      Resume_transaction.resume config ~keeper_name request
      |> Result.map_error Resume_transaction.error_to_string
      |> require_ok "observe prepared Resume_owner without registry projection"
    in
    check_resume_released interrupted.reservation_release;
    (match interrupted.projection with
     | Resume_transaction.Committed_followup_failed
         Resume_transaction.Registry_owner_missing -> ()
     | Resume_transaction.Committed_followup_failed failure ->
       Alcotest.fail
         (Resume_transaction.error_to_string
            { cause = failure; reservation_release = None })
     | Resume_transaction.Applied _ ->
       Alcotest.fail "Resume_owner claimed registry projection without a lane");
    let durably_resumed =
      Keeper_meta_store.read_meta config keeper_name
      |> require_ok "read interrupted Resume_owner owner"
      |> require_some "interrupted Resume_owner owner"
    in
    Alcotest.(check bool)
      "receipt projects durable resume before reporting missing registry"
      false
      durably_resumed.paused;
    ignore
      (Keeper_registry.For_testing.register
         ~base_path:config.Workspace.base_path
         keeper_name
         durably_resumed);
    (match Keeper_registry.get ~base_path:config.Workspace.base_path keeper_name with
     | Some _ -> ()
     | None -> Alcotest.fail "failed to restore registry lane for replay");
    let replay =
      Resume_transaction.resume config ~keeper_name request
      |> Result.map_error Resume_transaction.error_to_string
      |> require_ok "complete prepared Resume_owner receipt"
    in
    check_resume_released replay.reservation_release;
    (match replay.projection with
     | Resume_transaction.Applied _ -> ()
     | Resume_transaction.Committed_followup_failed failure ->
       Alcotest.fail
         (Resume_transaction.error_to_string
            { cause = failure; reservation_release = None }));
    (match replay.commit_status with
     | Resume_transaction.Already_committed -> ()
     | Resume_transaction.Committed ->
       Alcotest.fail "prepared Resume_owner receipt was written twice");
    let resumed =
      Keeper_meta_store.read_meta config keeper_name
      |> require_ok "read prepared-receipt projection"
      |> require_some "prepared-receipt projection"
    in
    Alcotest.(check bool) "prepared receipt clears durable pause" false resumed.paused)
;;

let test_resume_owner_commits_for_unregistered_durable_lane () =
  with_seeded_owner
    ~registered:false
    ~paused:true
    (fun config keeper_name source ->
       let request = resume_request "operator-resume-unregistered" in
       let outcome =
         Resume_transaction.resume config ~keeper_name request
         |> Result.map_error Resume_transaction.error_to_string
         |> require_ok "commit Resume_owner for unregistered lane"
       in
       check_resume_released outcome.reservation_release;
       (match outcome.commit_status with
        | Resume_transaction.Committed -> ()
        | Resume_transaction.Already_committed ->
          Alcotest.fail "unregistered Resume_owner replayed on first commit");
       (match outcome.projection with
        | Resume_transaction.Committed_followup_failed
            Resume_transaction.Registry_owner_missing -> ()
        | Resume_transaction.Committed_followup_failed failure ->
          Alcotest.fail
            (Resume_transaction.error_to_string
               { cause = failure; reservation_release = None })
        | Resume_transaction.Applied _ ->
          Alcotest.fail "unregistered Resume_owner claimed a live projection");
       let durable =
         Keeper_meta_store.read_meta config keeper_name
         |> require_ok "read unregistered resumed owner"
         |> require_some "unregistered resumed owner"
       in
       Alcotest.(check bool) "unregistered durable pause cleared" false durable.paused;
       let queue_state =
         Persistence.load_state_result
           ~base_path:config.Workspace.base_path
           ~keeper_name
         |> require_ok "load unregistered resumed queue"
       in
       Alcotest.(check bool)
         "unregistered Resume_owner preserves exact pending work"
         true
         (Queue.to_list (State.pending queue_state) = [ source ]))
;;



(* Why the recovery commits Pause and not Reset_latch. Both clear the
   transcript latch; only one leaves the keeper in a state resume accepts.
   Reset_latch drops the pause bit too, and resume then refuses the keeper as
   Durable_owner_not_paused, so the caller trades one refusal for another. *)
let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  let pool =
    Domain_pool.create
      ~sw
      ~domain_count:1
      (Eio.Stdenv.domain_mgr env)
  in
  Executor_pool_ref.For_testing.with_pool
    (Domain_pool.executor_pool pool)
  @@ fun () ->
  Alcotest.run
    "paused work cancellation transaction"
    [ ( "transaction"
      , [ Alcotest.test_case
            "pending cancellation commits exact remove"
            `Quick
            test_pending_cancellation_commits_exact_remove
        ; Alcotest.test_case
            "pending cancellation busy has zero mutation"
            `Quick
            test_pending_cancellation_busy_has_zero_mutation
        ; Alcotest.test_case
            "unrelated enqueue preserves pending incarnation"
            `Quick
            test_unrelated_enqueue_preserves_pending_incarnation
        ; Alcotest.test_case
            "reinserted source rejects old pending incarnation"
            `Quick
            test_reinserted_source_rejects_old_pending_incarnation
        ; Alcotest.test_case
            "Resume_owner commits receipt and preserves pending"
            `Quick
            test_resume_owner_commits_receipt_and_preserves_pending
        ; Alcotest.test_case
            "Resume_owner completes prepared receipt projection"
            `Quick
            test_resume_owner_completes_prepared_receipt_projection
        ; Alcotest.test_case
            "Resume_owner commits for unregistered durable lane"
            `Quick
            test_resume_owner_commits_for_unregistered_durable_lane

        ] )
    ]
;;
