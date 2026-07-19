type request =
  { source_revision : int64
  ; owner_generation : int
  ; lease : Keeper_registry_event_queue.lease
  ; operator_operation_id : string
  ; reason : string
  ; settled_at : float
  }

type failure =
  | Durable_meta_read_failed of string
  | Durable_meta_missing
  | Durable_owner_not_paused
  | Durable_owner_dead_tombstone
  | Durable_owner_generation_changed of
      { expected : int
      ; actual : int
      }
  | Registry_owner_not_paused of Keeper_state_machine.phase
  | Registry_owner_generation_changed of
      { expected : int
      ; actual : int
      }
  | Queue_commit_failed of string

type success =
  { settlement : Keeper_registry_event_queue.settle_result
  ; reservation_release : Keeper_lifecycle_reservation.release_outcome
  }

type error =
  | Reservation_conflict of Keeper_lifecycle_reservation.snapshot
  | Failed of
      { cause : failure
      ; reservation_release : Keeper_lifecycle_reservation.release_outcome
      }

let failure_to_string = function
  | Durable_meta_read_failed detail -> "durable Keeper metadata read failed: " ^ detail
  | Durable_meta_missing -> "durable Keeper metadata is missing"
  | Durable_owner_not_paused -> "durable Keeper owner is not paused"
  | Durable_owner_dead_tombstone -> "durable Keeper owner is a terminal dead tombstone"
  | Durable_owner_generation_changed { expected; actual } ->
    Printf.sprintf
      "durable Keeper owner generation changed: expected %d, actual %d"
      expected
      actual
  | Registry_owner_not_paused phase ->
    Printf.sprintf
      "live Keeper owner is not paused: phase=%s"
      (Keeper_state_machine.phase_to_string phase)
  | Registry_owner_generation_changed { expected; actual } ->
    Printf.sprintf
      "live Keeper owner generation changed: expected %d, actual %d"
      expected
      actual
  | Queue_commit_failed detail -> "accepted cancellation commit failed: " ^ detail
;;

let release_outcome_to_string = function
  | Keeper_lifecycle_reservation.Released -> "released"
  | Keeper_lifecycle_reservation.Release_missing -> "release_missing"
  | Keeper_lifecycle_reservation.Release_not_owner owner ->
    "release_not_owner: " ^ Keeper_lifecycle_reservation.snapshot_to_string owner
;;

let error_to_string = function
  | Reservation_conflict owner ->
    "Keeper lifecycle reservation conflict: "
    ^ Keeper_lifecycle_reservation.snapshot_to_string owner
  | Failed { cause; reservation_release } ->
    Printf.sprintf
      "%s; reservation_release=%s"
      (failure_to_string cause)
      (release_outcome_to_string reservation_release)
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
     | Keeper_lifecycle_admission.Dead_tombstone ->
       Error Durable_owner_dead_tombstone
     | Keeper_lifecycle_admission.Paused _ ->
       if meta.runtime.generation <> expected_generation
       then
         Error
           (Durable_owner_generation_changed
              { expected = expected_generation; actual = meta.runtime.generation })
       else Ok meta)
;;

let validate_registry_owner ~base_path ~keeper_name ~expected_generation =
  match Keeper_registry.get ~base_path keeper_name with
  | None -> Ok ()
  | Some entry
    when (not entry.meta.paused) || entry.phase <> Keeper_state_machine.Paused ->
    Error (Registry_owner_not_paused entry.phase)
  | Some entry when entry.meta.runtime.generation <> expected_generation ->
    Error
      (Registry_owner_generation_changed
         { expected = expected_generation
         ; actual = entry.meta.runtime.generation
         })
  | Some _ -> Ok ()
;;

let run config ~keeper_name request =
  let base_path = config.Workspace.base_path in
  match
    validate_durable_owner
      config
      ~keeper_name
      ~expected_generation:request.owner_generation
  with
  | Error _ as error -> error
  | Ok durable_meta ->
    (match
       validate_registry_owner
         ~base_path
         ~keeper_name
         ~expected_generation:request.owner_generation
     with
     | Error _ as error -> error
     | Ok () ->
       let cancellation : Keeper_registry_event_queue.accepted_cancellation =
         { source_revision = request.source_revision
         ; owner_generation = request.owner_generation
         ; operator_operation_id = request.operator_operation_id
         ; reason = request.reason
         }
       in
       Keeper_registry_event_queue.cancel_accepted_result
         ~base_path
         keeper_name
         ~current_owner_generation:durable_meta.runtime.generation
         ~settled_at:request.settled_at
         ~lease:request.lease
         ~cancellation
       |> Result.map_error (fun detail -> Queue_commit_failed detail))
;;

let cancel config ~keeper_name request =
  match
    Keeper_lifecycle_reservation.acquire
      ~base_path:config.Workspace.base_path
      ~keeper_name
      ~expected_generation:request.owner_generation
      ~purpose:Keeper_lifecycle_reservation.Paused_work_disposition
  with
  | Error (Keeper_lifecycle_reservation.Already_reserved owner) ->
    Error (Reservation_conflict owner)
  | Ok token ->
    (try
       let outcome = run config ~keeper_name request in
       let reservation_release = Keeper_lifecycle_reservation.release token in
       match outcome with
       | Ok settlement -> Ok { settlement; reservation_release }
       | Error cause -> Error (Failed { cause; reservation_release })
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
            (release_outcome_to_string release));
       raise exn)
;;
