type pending_request =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; owner_nonce : int
  ; operator_operation_id : string
  ; reason : string
  }

type failure =
  | Durable_meta_read_failed of string
  | Durable_meta_missing
  | Durable_owner_not_paused
  | Durable_owner_nonce_changed of
      { expected : int
      ; actual : int
      }
  | Registry_owner_not_paused of Keeper_state_machine.phase
  | Registry_owner_nonce_changed of
      { expected : int
      ; actual : int
      }
  | Queue_replay_failed of string
  | Queue_commit_failed of string

type success =
  { transition : Keeper_registry_event_queue.transition_result
  ; reservation_release : Keeper_lifecycle_reservation.release_outcome option
  }

type error =
  | Admission_busy of Keeper_owner.autonomous_block
  | Owner_unavailable of string
  | Reservation_conflict of Keeper_lifecycle_reservation.snapshot
  | Failed of
      { cause : failure
      ; reservation_release : Keeper_lifecycle_reservation.release_outcome option
      }

let failure_to_string = function
  | Durable_meta_read_failed detail -> "durable Keeper metadata read failed: " ^ detail
  | Durable_meta_missing -> "durable Keeper metadata is missing"
  | Durable_owner_not_paused -> "durable Keeper owner is not paused"
  | Durable_owner_nonce_changed { expected; actual } ->
    Printf.sprintf
      "durable Keeper owner generation changed: expected %d, actual %d"
      expected
      actual
  | Registry_owner_not_paused phase ->
    Printf.sprintf
      "live Keeper owner is not paused: phase=%s"
      (Keeper_state_machine.phase_to_string phase)
  | Registry_owner_nonce_changed { expected; actual } ->
    Printf.sprintf
      "live Keeper owner generation changed: expected %d, actual %d"
      expected
      actual
  | Queue_replay_failed detail -> "accepted cancellation replay failed: " ^ detail
  | Queue_commit_failed detail -> "accepted cancellation commit failed: " ^ detail
;;

let error_to_string = function
  | Admission_busy block ->
    Printf.sprintf
      "keeper_owner_busy: operation=cancel_pending %s"
      (Keeper_owner.autonomous_block_to_string block)
  | Owner_unavailable detail -> "Keeper owner unavailable: " ^ detail
  | Reservation_conflict owner ->
    "Keeper lifecycle reservation conflict: "
    ^ Keeper_lifecycle_reservation.snapshot_to_string owner
  | Failed { cause; reservation_release } ->
    (match reservation_release with
     | None -> failure_to_string cause
     | Some release ->
       Printf.sprintf
         "%s; reservation_release=%s"
         (failure_to_string cause)
         (Keeper_lifecycle_reservation.release_outcome_to_string release))
;;

let cancellation_of_pending_request (request : pending_request) :
  Keeper_registry_event_queue.accepted_cancellation
  =
  { source = request.source
  ; source_incarnation = request.source_incarnation
  ; owner_nonce = request.owner_nonce
  ; operator_operation_id = request.operator_operation_id
  ; reason = request.reason
  }
;;

let replay_committed ~base_path ~keeper_name replay =
  match Keeper_event_queue_persistence.load_state_result ~base_path ~keeper_name with
  | Error detail -> Error (Queue_replay_failed detail)
  | Ok state ->
    replay state
    |> Result.map_error (fun detail -> Queue_replay_failed detail)
;;

let validate_durable_owner config ~keeper_name ~expected_generation =
  match Keeper_meta_store.read_meta config keeper_name with
  | Error detail -> Error (Durable_meta_read_failed detail)
  | Ok None -> Error Durable_meta_missing
  | Ok (Some meta) ->
    (match
       Keeper_lifecycle_admission.state
         ~paused:meta.paused
         ~latched_reason:meta.latched_reason
     with
     | Keeper_lifecycle_admission.Active -> Error Durable_owner_not_paused
     | Keeper_lifecycle_admission.Paused _ -> Ok meta)
;;

let validate_registry_owner ~base_path ~keeper_name ~expected_generation =
  match Keeper_registry.get ~base_path keeper_name with
  | None -> Ok ()
  | Some entry
    when (not entry.meta.paused) || entry.phase <> Keeper_state_machine.Paused ->
    Error (Registry_owner_not_paused entry.phase)
  | Some entry when entry.meta.runtime.nonce <> expected_generation ->
    Error
      (Registry_owner_nonce_changed
         { expected = expected_generation
         ; actual = entry.meta.runtime.nonce
         })
  | Some _ -> Ok ()
;;

let run config ~keeper_name ~owner_nonce commit =
  let base_path = config.Workspace.base_path in
  match
    validate_durable_owner
      config
      ~keeper_name
      ~expected_generation:owner_nonce
  with
  | Error _ as error -> error
  | Ok durable_meta ->
    (match
       validate_registry_owner
         ~base_path
         ~keeper_name
         ~expected_generation:owner_nonce
     with
     | Error _ as error -> error
     | Ok () ->
       commit durable_meta.runtime.nonce
       |> Result.map_error (fun detail -> Queue_commit_failed detail))
;;

let cancel_with_lifecycle
      config
      ~keeper_name
      ~owner_nonce
      ~replay
      ~commit
  =
  let base_path = config.Workspace.base_path in
  let finish token outcome =
    let reservation_release = Keeper_lifecycle_reservation.release token in
    match outcome with
    | Ok transition -> Ok { transition; reservation_release = Some reservation_release }
    | Error cause ->
      Error (Failed { cause; reservation_release = Some reservation_release })
  in
  let acquire () =
    match
      Keeper_lifecycle_reservation.acquire
        ~base_path
        ~keeper_name
        ~expected_generation:owner_nonce
        ~purpose:Keeper_lifecycle_reservation.Paused_work_disposition
    with
    | Error (Keeper_lifecycle_reservation.Already_reserved owner) ->
      Error (Reservation_conflict owner)
    | Ok token ->
      (try
         match replay_committed ~base_path ~keeper_name replay with
         | Error cause -> finish token (Error cause)
         | Ok (Some receipt) ->
           finish token (Ok (Keeper_registry_event_queue.Transition_already_applied receipt))
         | Ok None ->
           finish
             token
             (run config ~keeper_name ~owner_nonce commit)
       with
       | exn ->
         let release = Keeper_lifecycle_reservation.release token in
         (match release with
          | Keeper_lifecycle_reservation.Released -> ()
          | Keeper_lifecycle_reservation.Release_missing
          | Keeper_lifecycle_reservation.Release_not_owner _ ->
            Log.Keeper.error
              "paused cancellation exception release failed keeper=%s outcome=%s"
              keeper_name
              (Keeper_lifecycle_reservation.release_outcome_to_string release));
         raise exn)
  in
  match replay_committed ~base_path ~keeper_name replay with
  | Error cause -> Error (Failed { cause; reservation_release = None })
  | Ok (Some receipt) ->
    Ok
      { transition = Keeper_registry_event_queue.Transition_already_applied receipt
      ; reservation_release = None
      }
  | Ok None ->
    (match
       Keeper_owner_registry.run_maintenance_if_idle
         ~base_path
         ~keeper_name
         acquire
     with
     | Ok (`Ran outcome) -> outcome
     | Ok (`Busy block) -> Error (Admission_busy block)
     | Error error ->
       Error
         (Owner_unavailable (Keeper_owner_registry.command_error_to_string error)))
;;

let cancel_pending config ~keeper_name request =
  let cancellation = cancellation_of_pending_request request in
  cancel_with_lifecycle
    config
    ~keeper_name
    ~owner_nonce:request.owner_nonce
    ~replay:
      (Keeper_event_queue_state.accepted_pending_cancellation_replay cancellation)
    ~commit:(fun current_owner_nonce ->
      Keeper_registry_event_queue.cancel_pending_accepted_result
        ~base_path:config.Workspace.base_path
        keeper_name
        ~current_owner_nonce
        ~applied_at:(Time_compat.now ())
        ~cancellation)
;;
