open Masc

module Queue = Keeper_event_queue
module Persistence = Keeper_event_queue_persistence
module Registry_queue = Keeper_registry_event_queue
module State = Keeper_event_queue_state
module Transaction = Keeper_paused_work_cancellation_transaction

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
      Keeper_registry.clear ();
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
         ; runtime = { meta.runtime with generation }
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
         ignore (Keeper_registry.register ~base_path keeper_name persisted);
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
           ~base_path
           ~keeper_name
           ~claimed_at:2.0
           ~ready:(fun _ -> true)
           ()
         |> require_ok "claim accepted source"
         |> require_some "accepted source lease"
       in
       let source_revision =
         Persistence.load_state_result ~base_path ~keeper_name
         |> require_ok "load accepted source revision"
         |> State.revision
       in
       let request : Transaction.request =
         { source_revision
         ; owner_generation = generation
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
         ; owner_generation = generation
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
          { resumed.runtime with generation = resumed.runtime.generation + 1 }
      }
    in
    Keeper_meta_store.write_meta config resumed
    |> require_ok "persist replacement owner generation";
    Keeper_registry.clear ();
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
             { resumed.runtime with generation = resumed.runtime.generation + 1 }
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
    let stale = { request with owner_generation = 12 } in
    (match Transaction.cancel config ~keeper_name stale with
     | Error
         (Transaction.Failed
            { cause =
                Transaction.Durable_owner_generation_changed
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
        ] )
    ]
;;
