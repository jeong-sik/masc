open Masc

module Queue = Keeper_event_queue
module Persistence = Keeper_event_queue_persistence
module Registry_queue = Keeper_registry_event_queue
module State = Keeper_event_queue_state
module Transaction = Keeper_paused_work_cancellation_transaction
module Disposition_receipt = Keeper_paused_work_disposition_receipt
module Resume_transaction = Keeper_paused_work_resume_transaction
module Heartbeat_testing = Keeper_heartbeat_loop.For_testing

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

let with_seeded_owner ?(registered = true) ?latched_reason ~paused ~generation f =
  let base_path = Filename.temp_dir "keeper-paused-cancel-transaction" "" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.For_testing.clear ();
      remove_tree base_path)
    (fun () ->
       let config = Workspace.default_config base_path in
       ignore (Workspace.init config ~agent_name:(Some "operator"));
       let keeper_name = "paused-cancel-owner" in
       let meta =
         Masc_test_deps.meta_of_json_fixture
           (`Assoc
              [ "name", `String keeper_name
              ; "agent_name", `String (Keeper_identity.keeper_agent_name keeper_name)
              ; "trace_id", `String "trace-paused-cancel-owner"
              ; "runtime_id", `String "runtime.primary"
              ; "autoboot_enabled", `Bool false
              ])
         |> require_ok "parse Keeper metadata fixture"
       in
       let meta =
         { meta with
           paused
         ; latched_reason
         ; runtime = { meta.runtime with nonce = meta.runtime.nonce }
         }
       in
       Keeper_meta_store.write_meta config meta |> require_ok "persist Keeper metadata";
       let persisted =
         Keeper_meta_store.read_meta config keeper_name
         |> require_ok "read persisted Keeper metadata"
         |> require_some "persisted Keeper metadata"
       in
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

let with_lane ?registered ?latched_reason ~paused ~generation f =
  with_seeded_owner
    ?registered
    ?latched_reason
    ~paused
    ~generation
    (fun config keeper_name _source ->
       let lease =
         Persistence.claim_when_result
           ~base_path:config.Workspace.base_path
           ~keeper_name
           ~claimed_at:2.0
           ~ready:(fun _ -> true)
           ()
         |> require_ok "claim accepted source"
         |> require_some "accepted source lease"
       in
       let source_revision =
         Persistence.load_state_result ~base_path:config.Workspace.base_path ~keeper_name
         |> require_ok "load accepted source revision"
         |> State.revision
       in
       let request : Transaction.request =
         { source_revision
         ; owner_nonce = generation
         ; lease
         ; operator_operation_id = "operator-cancel-1"
         ; reason = "operator rejected retained paused work"
         ; settled_at = 3.0
         }
       in
       f config keeper_name request)
;;

let with_pending_lane ?registered ?latched_reason ~paused ~generation f =
  with_seeded_owner
    ?registered
    ?latched_reason
    ~paused
    ~generation
    (fun config keeper_name source ->
       let source_revision =
         Persistence.load_state_result
           ~base_path:config.Workspace.base_path
           ~keeper_name
         |> require_ok "load pending accepted source revision"
         |> State.revision
       in
       let request : Transaction.pending_request =
         { source
         ; source_revision
         ; owner_nonce = generation
         ; operator_operation_id = "operator-pending-cancel-1"
         ; reason = "operator rejected exact pending paused work"
         ; settled_at = 3.0
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

let test_paused_owner_cancellation_commits_once () =
  with_lane ~paused:true ~generation:11 (fun config keeper_name request ->
    let first =
      Transaction.cancel config ~keeper_name request
      |> Result.map_error Transaction.error_to_string
      |> require_ok "cancel accepted paused work"
    in
    check_released first.reservation_release;
    let receipt =
      match first.settlement with
      | Registry_queue.Settled receipt -> receipt
      | Registry_queue.Already_settled _ ->
        Alcotest.fail "first paused cancellation was already settled"
      | Registry_queue.Committed_followup_failed { receipt; _ } -> receipt
    in
    let current_meta =
      Keeper_meta_store.read_meta config keeper_name
      |> require_ok "read committed cancellation owner"
      |> require_some "committed cancellation owner"
    in
    let resumed =
      let resumed = Keeper_meta_contract.mark_resumed current_meta in
      { resumed with
        runtime =
          { resumed.runtime with nonce = resumed.runtime.nonce + 1 }
      }
    in
    Keeper_meta_store.write_meta config resumed
    |> require_ok "persist replacement owner generation";
    Keeper_registry.For_testing.clear ();
    let replay =
      Transaction.cancel config ~keeper_name request
      |> Result.map_error Transaction.error_to_string
      |> require_ok "replay accepted paused cancellation"
    in
    check_replayed_without_reservation replay.reservation_release;
    (match replay.settlement with
     | Registry_queue.Already_settled replayed ->
       Alcotest.(check bool)
         "replay returns the canonical receipt"
         true
         (State.transition_receipt_equal receipt replayed)
     | Registry_queue.Settled _ | Registry_queue.Committed_followup_failed _ ->
       Alcotest.fail "paused cancellation replay committed twice");
    let state =
      Persistence.load_state_result
        ~base_path:config.Workspace.base_path
        ~keeper_name
      |> require_ok "load cancelled paused lane"
    in
    Alcotest.(check int) "accepted lease removed" 0 (List.length (State.leases state));
    Alcotest.(check int)
      "exact source retained in transition outbox"
      1
      (List.length (State.transition_outbox state)))
;;

let test_running_owner_is_rejected_before_commit () =
  with_lane ~paused:false ~generation:12 (fun config keeper_name request ->
    (match Transaction.cancel config ~keeper_name request with
     | Error
         (Transaction.Failed
            { cause = Transaction.Durable_owner_not_paused
            ; reservation_release
            }) ->
       check_released reservation_release
     | Error error -> Alcotest.fail (Transaction.error_to_string error)
     | Ok _ -> Alcotest.fail "running Keeper owner accepted paused cancellation");
    let state =
      Persistence.load_state_result
        ~base_path:config.Workspace.base_path
        ~keeper_name
      |> require_ok "load rejected running lane"
    in
    Alcotest.(check int)
      "rejected running owner retains active lease"
      1
      (List.length (State.leases state)))
;;

let test_durable_paused_owner_can_cancel_without_live_registry () =
  with_lane ~registered:false ~paused:true ~generation:14 (fun config keeper_name request ->
    let outcome =
      Transaction.cancel config ~keeper_name request
      |> Result.map_error Transaction.error_to_string
      |> require_ok "cancel durable paused work without live registry"
    in
    check_released outcome.reservation_release;
    (match outcome.settlement with
     | Registry_queue.Settled _ | Registry_queue.Committed_followup_failed _ -> ()
     | Registry_queue.Already_settled _ ->
       Alcotest.fail "first durable paused cancellation was already settled");
    let state =
      Persistence.load_state_result
        ~base_path:config.Workspace.base_path
        ~keeper_name
      |> require_ok "load cancelled unregistered lane"
    in
    Alcotest.(check int)
      "unregistered paused lease removed"
      0
      (List.length (State.leases state)))
;;

let test_dead_tombstone_cannot_use_operator_cancellation () =
  with_lane
    ~registered:false
    ~latched_reason:Keeper_latched_reason.Dead_tombstone
    ~paused:true
    ~generation:15
    (fun config keeper_name request ->
       (match Transaction.cancel config ~keeper_name request with
        | Error
            (Transaction.Failed
               { cause = Transaction.Durable_owner_dead_tombstone
               ; reservation_release
               }) ->
          check_released reservation_release
        | Error error -> Alcotest.fail (Transaction.error_to_string error)
        | Ok _ -> Alcotest.fail "dead tombstone accepted operator cancellation");
       let state =
         Persistence.load_state_result
           ~base_path:config.Workspace.base_path
           ~keeper_name
         |> require_ok "load rejected dead-tombstone lane"
       in
       Alcotest.(check int)
         "dead-tombstone rejection retains active lease"
         1
         (List.length (State.leases state)))
;;

let test_pending_cancellation_replays_after_owner_transition () =
  with_pending_lane
    ~registered:false
    ~paused:true
    ~generation:16
    (fun config keeper_name request ->
       let first =
         Transaction.cancel_pending config ~keeper_name request
         |> Result.map_error Transaction.error_to_string
         |> require_ok "cancel pending paused work"
       in
       check_released first.reservation_release;
       (match first.settlement with
        | Registry_queue.Settled _ | Registry_queue.Committed_followup_failed _ -> ()
        | Registry_queue.Already_settled _ ->
          Alcotest.fail "first pending transaction was already settled");
       let current_meta =
         Keeper_meta_store.read_meta config keeper_name
         |> require_ok "read pending cancellation owner"
         |> require_some "pending cancellation owner"
       in
       let resumed =
         let resumed = Keeper_meta_contract.mark_resumed current_meta in
         { resumed with
           runtime =
             { resumed.runtime with nonce = resumed.runtime.nonce + 1 }
         }
       in
       Keeper_meta_store.write_meta config resumed
       |> require_ok "persist replacement after pending cancellation";
       let replay =
         Transaction.cancel_pending config ~keeper_name request
         |> Result.map_error Transaction.error_to_string
         |> require_ok "replay pending cancellation after owner transition"
       in
       check_replayed_without_reservation replay.reservation_release;
       (match replay.settlement with
        | Registry_queue.Already_settled _ -> ()
        | Registry_queue.Settled _ | Registry_queue.Committed_followup_failed _ ->
          Alcotest.fail "pending transaction replay committed twice"))
;;

let test_stale_generation_is_rejected_before_commit () =
  with_lane ~paused:true ~generation:13 (fun config keeper_name request ->
    let stale = { request with owner_nonce = 12 } in
    (match Transaction.cancel config ~keeper_name stale with
     | Error
         (Transaction.Failed
            { cause =
                Transaction.Durable_owner_nonce_changed
                  { expected = 12; actual = 13 }
            ; reservation_release
            }) ->
       check_released reservation_release
     | Error error -> Alcotest.fail (Transaction.error_to_string error)
     | Ok _ -> Alcotest.fail "stale Keeper generation accepted cancellation");
    let state =
      Persistence.load_state_result
        ~base_path:config.Workspace.base_path
        ~keeper_name
      |> require_ok "load stale-generation lane"
    in
    Alcotest.(check int)
      "stale generation retains active lease"
      1
      (List.length (State.leases state)))
;;

let resume_request generation operation_id : Resume_transaction.request =
  { owner_nonce = generation
  ; operator_operation_id = operation_id
  }
;;

let test_resume_owner_commits_receipt_and_preserves_pending () =
  with_seeded_owner ~paused:true ~generation:21 (fun config keeper_name source ->
    let request = resume_request 21 "operator-resume-1" in
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
    let conflicting = { request with owner_nonce = 20 } in
    (match Resume_transaction.resume config ~keeper_name conflicting with
     | Error { Resume_transaction.cause = Resume_transaction.Receipt_conflict _; _ } -> ()
     | Error error -> Alcotest.fail (Resume_transaction.error_to_string error)
     | Ok _ -> Alcotest.fail "Resume_owner operation ID accepted a different request");
    let second_operation = resume_request 21 "operator-resume-2" in
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
  with_seeded_owner ~paused:true ~generation:22 (fun config keeper_name _source ->
    let request = resume_request 22 "operator-resume-prepared" in
    let durable =
      Keeper_meta_store.read_meta config keeper_name
      |> require_ok "read prepared Resume_owner durable owner"
      |> require_some "prepared Resume_owner durable owner"
    in
    let prepared : Disposition_receipt.t =
      { keeper_name
      ; expected_trace_id = durable.runtime.trace_id
      ; expected_generation = request.owner_nonce
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

let test_resume_owner_rejects_stale_generation_without_receipt () =
  with_seeded_owner ~paused:true ~generation:23 (fun config keeper_name _source ->
    let request = resume_request 22 "operator-resume-stale" in
    (match Resume_transaction.resume config ~keeper_name request with
     | Error
         { Resume_transaction.cause =
             Resume_transaction.Durable_owner_nonce_changed
               { expected = 22; actual = 23 }
         ; reservation_release = Some release
         } ->
       check_resume_released release
     | Error error -> Alcotest.fail (Resume_transaction.error_to_string error)
     | Ok _ -> Alcotest.fail "stale Resume_owner generation committed");
    match
      Disposition_receipt.load
        config
        ~keeper_name
        ~operator_operation_id:request.operator_operation_id
    with
    | Ok None -> ()
    | Ok (Some _) -> Alcotest.fail "stale Resume_owner persisted a receipt"
    | Error detail -> Alcotest.fail detail)
;;

let test_resume_owner_commits_for_unregistered_durable_lane () =
  with_seeded_owner
    ~registered:false
    ~paused:true
    ~generation:25
    (fun config keeper_name source ->
       let request = resume_request 25 "operator-resume-unregistered" in
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

let test_resume_owner_rejects_dead_tombstone_without_receipt () =
  with_seeded_owner
    ~registered:false
    ~latched_reason:Keeper_latched_reason.Dead_tombstone
    ~paused:true
    ~generation:24
    (fun config keeper_name _source ->
       let request = resume_request 24 "operator-resume-dead" in
       (match Resume_transaction.resume config ~keeper_name request with
        | Error
            { Resume_transaction.cause = Resume_transaction.Durable_owner_dead_tombstone
            ; reservation_release = Some release
            } ->
          check_resume_released release
        | Error error -> Alcotest.fail (Resume_transaction.error_to_string error)
        | Ok _ -> Alcotest.fail "Resume_owner revived a Dead tombstone");
       match
         Disposition_receipt.load
           config
           ~keeper_name
           ~operator_operation_id:request.operator_operation_id
       with
       | Ok None -> ()
       | Ok (Some _) -> Alcotest.fail "Dead Resume_owner persisted a receipt"
       | Error detail -> Alcotest.fail detail)
;;

let test_resume_owner_rejects_transcript_reset_without_receipt () =
  with_seeded_owner
    ~registered:false
    ~latched_reason:Keeper_latched_reason.Transcript_corruption_reset_required
    ~paused:true
    ~generation:24
    (fun config keeper_name _source ->
       let request = resume_request 24 "operator-resume-corrupted" in
       (match Resume_transaction.resume config ~keeper_name request with
        | Error
            { Resume_transaction.cause =
                Resume_transaction.Durable_owner_transcript_reset_required
            ; reservation_release = Some release
            } ->
          check_resume_released release
        | Error error -> Alcotest.fail (Resume_transaction.error_to_string error)
        | Ok _ ->
          Alcotest.fail "Resume_owner replayed a structurally corrupted checkpoint");
       match
         Disposition_receipt.load
           config
           ~keeper_name
           ~operator_operation_id:request.operator_operation_id
       with
       | Ok None -> ()
       | Ok (Some _) ->
         Alcotest.fail "reset-required Resume_owner persisted a receipt"
       | Error detail -> Alcotest.fail detail)
;;

let test_transcript_corruption_pause_precedes_settlement () =
  let stop = Atomic.make false in
  let calls = ref [] in
  let result =
    Heartbeat_testing.commit_transcript_corruption
      ~stop
      ~persist_pause:(fun () ->
        calls := "pause" :: !calls;
        Ok `Persisted)
      ~settle:(fun () ->
        calls := "settle" :: !calls;
        Ok ())
      ()
  in
  Alcotest.(check bool) "corrupted fiber is stopped" true (Atomic.get stop);
  Alcotest.(check (list string))
    "durable pause commits before terminal settlement"
    [ "pause"; "settle" ]
    (List.rev !calls);
  Alcotest.(check bool)
    "both commits are reported"
    true
    (match result with
     | Heartbeat_testing.Transcript_pause_and_settlement_persisted -> true
     | Heartbeat_testing.Transcript_pause_persisted
     | Heartbeat_testing.Transcript_pause_persistence_failed _
     | Heartbeat_testing.Transcript_pause_settlement_failed _ ->
       false)
;;

let test_transcript_corruption_pause_failure_preserves_lease () =
  let stop = Atomic.make false in
  let settlement_called = ref false in
  let result =
    Heartbeat_testing.commit_transcript_corruption
      ~stop
      ~persist_pause:(fun () -> Ok `No_durable_meta)
      ~settle:(fun () ->
        settlement_called := true;
        Ok ())
      ()
  in
  Alcotest.(check bool) "corrupted fiber remains stopped" true (Atomic.get stop);
  Alcotest.(check bool)
    "terminal settlement stays locked"
    false
    !settlement_called;
  Alcotest.(check bool)
    "pause failure is typed"
    true
    (match result with
     | Heartbeat_testing.Transcript_pause_persistence_failed _ -> true
     | Heartbeat_testing.Transcript_pause_persisted
     | Heartbeat_testing.Transcript_pause_and_settlement_persisted
     | Heartbeat_testing.Transcript_pause_settlement_failed _ ->
       false)
;;

let test_unleased_transcript_corruption_only_persists_pause () =
  let stop = Atomic.make false in
  let result =
    Heartbeat_testing.commit_transcript_corruption
      ~stop
      ~persist_pause:(fun () -> Ok `Persisted)
      ()
  in
  Alcotest.(check bool)
    "unleased corruption commits only durable pause"
    true
    (match result with
     | Heartbeat_testing.Transcript_pause_persisted -> true
     | Heartbeat_testing.Transcript_pause_and_settlement_persisted
     | Heartbeat_testing.Transcript_pause_persistence_failed _
     | Heartbeat_testing.Transcript_pause_settlement_failed _ ->
       false)
;;

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Alcotest.run
    "paused work cancellation transaction"
    [ ( "transaction"
      , [ Alcotest.test_case
            "paused owner cancellation commits once"
            `Quick
            test_paused_owner_cancellation_commits_once
        ; Alcotest.test_case
            "running owner is rejected before commit"
            `Quick
            test_running_owner_is_rejected_before_commit
        ; Alcotest.test_case
            "stale generation is rejected before commit"
            `Quick
            test_stale_generation_is_rejected_before_commit
        ; Alcotest.test_case
            "durable paused owner can cancel without live registry"
            `Quick
            test_durable_paused_owner_can_cancel_without_live_registry
        ; Alcotest.test_case
            "dead tombstone cannot use operator cancellation"
            `Quick
            test_dead_tombstone_cannot_use_operator_cancellation
        ; Alcotest.test_case
            "pending cancellation replays after owner transition"
            `Quick
            test_pending_cancellation_replays_after_owner_transition
        ; Alcotest.test_case
            "Resume_owner commits receipt and preserves pending"
            `Quick
            test_resume_owner_commits_receipt_and_preserves_pending
        ; Alcotest.test_case
            "Resume_owner completes prepared receipt projection"
            `Quick
            test_resume_owner_completes_prepared_receipt_projection
        ; Alcotest.test_case
            "Resume_owner rejects stale generation without receipt"
            `Quick
            test_resume_owner_rejects_stale_generation_without_receipt
        ; Alcotest.test_case
            "Resume_owner commits for unregistered durable lane"
            `Quick
            test_resume_owner_commits_for_unregistered_durable_lane
        ; Alcotest.test_case
            "Resume_owner rejects Dead tombstone without receipt"
            `Quick
            test_resume_owner_rejects_dead_tombstone_without_receipt
        ; Alcotest.test_case
            "Resume_owner rejects transcript reset without receipt"
            `Quick
            test_resume_owner_rejects_transcript_reset_without_receipt
        ; Alcotest.test_case
            "transcript pause precedes settlement"
            `Quick
            test_transcript_corruption_pause_precedes_settlement
        ; Alcotest.test_case
            "transcript pause failure preserves lease"
            `Quick
            test_transcript_corruption_pause_failure_preserves_lease
        ; Alcotest.test_case
            "unleased transcript only persists pause"
            `Quick
            test_unleased_transcript_corruption_only_persists_pause
        ] )
    ]
;;
