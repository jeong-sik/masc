type request =
  { source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; owner_nonce : int
  ; source_receipt : Keeper_event_queue_state.source_terminal_receipt
  ; operator_operation_id : string
  ; settled_at : float
  }

type failure =
  | Invalid_request of string
  | Reservation_conflict of Keeper_lifecycle_reservation.snapshot
  | Receipt_lock_failed of string
  | Receipt_read_failed of string
  | Receipt_conflict of Keeper_paused_work_disposition_receipt.t
  | Receipt_write_failed of string
  | Durable_meta_read_failed of string
  | Durable_meta_missing
  | Durable_owner_not_paused
  | Durable_owner_dead_tombstone
  | Durable_owner_nonce_changed of
      { expected : int
      ; actual : int
      }
  | Durable_owner_identity_changed
  | Source_queue_validation_failed of string
  | Committed_settlement_failed of string

type error =
  { cause : failure
  ; reservation_release : Keeper_lifecycle_reservation.release_outcome option
  }

type commit_status =
  | Committed
  | Already_committed

type projection =
  | Applied of Keeper_registry_event_queue.settle_result
  | Committed_followup_failed of failure

type success =
  { receipt : Keeper_paused_work_disposition_receipt.t
  ; commit_status : commit_status
  ; projection : projection
  ; reservation_release : Keeper_lifecycle_reservation.release_outcome
  }

let ( let* ) = Result.bind

let failure_to_string = function
  | Invalid_request detail ->
    "invalid Settle_from_source_terminal request: " ^ detail
  | Reservation_conflict owner ->
    "Settle_from_source_terminal lifecycle reservation conflict: "
    ^ Keeper_lifecycle_reservation.snapshot_to_string owner
  | Receipt_lock_failed detail ->
    "Settle_from_source_terminal receipt lock failed: " ^ detail
  | Receipt_read_failed detail ->
    "Settle_from_source_terminal receipt read failed: " ^ detail
  | Receipt_conflict receipt ->
    Printf.sprintf
      "Settle_from_source_terminal operation ID conflicts with keeper=%s generation=%d requested_at=%.17g"
      receipt.keeper_name
      receipt.expected_generation
      receipt.requested_at
  | Receipt_write_failed detail ->
    "Settle_from_source_terminal receipt write failed: " ^ detail
  | Durable_meta_read_failed detail ->
    "Settle_from_source_terminal durable metadata read failed: " ^ detail
  | Durable_meta_missing ->
    "Settle_from_source_terminal durable Keeper metadata is missing"
  | Durable_owner_not_paused ->
    "Settle_from_source_terminal requires a paused Keeper"
  | Durable_owner_dead_tombstone ->
    "Settle_from_source_terminal cannot use a Dead tombstone"
  | Durable_owner_nonce_changed { expected; actual } ->
    Printf.sprintf
      "Settle_from_source_terminal generation changed: expected %d, actual %d"
      expected
      actual
  | Durable_owner_identity_changed ->
    "Settle_from_source_terminal trace identity changed"
  | Source_queue_validation_failed detail ->
    "Settle_from_source_terminal source queue validation failed: " ^ detail
  | Committed_settlement_failed detail ->
    "Settle_from_source_terminal committed receipt but settlement failed: " ^ detail
;;

let error_to_string error =
  let base = failure_to_string error.cause in
  match error.reservation_release with
  | None -> base
  | Some Keeper_lifecycle_reservation.Released ->
    base ^ "; reservation_release=released"
  | Some Keeper_lifecycle_reservation.Release_missing ->
    base ^ "; reservation_release=release_missing"
  | Some (Keeper_lifecycle_reservation.Release_not_owner owner) ->
    base
    ^ "; reservation_release=release_not_owner: "
    ^ Keeper_lifecycle_reservation.snapshot_to_string owner
;;

let validate_request request =
  if request.owner_nonce < 0
  then Error "owner generation must not be negative"
  else if Int64.compare request.source_revision 0L < 0
  then Error "source revision must not be negative"
  else if String.equal (String.trim request.source.post_id) ""
  then Error "source post id must not be empty"
  else if String.equal (String.trim request.operator_operation_id) ""
  then Error "operator operation ID must not be empty"
  else if not (Float.is_finite request.settled_at)
  then Error "settlement time must be finite"
  else
    let* exact =
      Keeper_event_queue_state.source_terminal_receipt_of_stimulus request.source
    in
    if exact = request.source_receipt
    then Ok ()
    else Error "source receipt does not match the exact source event"
;;

let read_meta config keeper_name =
  match Keeper_meta_store.read_meta config keeper_name with
  | Error detail -> Error (Durable_meta_read_failed detail)
  | Ok None -> Error Durable_meta_missing
  | Ok (Some meta) -> Ok meta
;;

let validate_paused_owner request (meta : Keeper_meta_contract.keeper_meta) =
  match
    Keeper_lifecycle_admission.state
      ~paused:meta.paused
      ~latched_reason:meta.latched_reason
  with
  | Keeper_lifecycle_admission.Active -> Error Durable_owner_not_paused
  | Keeper_lifecycle_admission.Dead_tombstone ->
    Error Durable_owner_dead_tombstone
  | Keeper_lifecycle_admission.Paused _ ->
    if Int.equal meta.runtime.nonce request.owner_nonce
    then Ok meta
    else
      Error
        (Durable_owner_nonce_changed
           { expected = request.owner_nonce; actual = meta.runtime.nonce })
;;

let validate_source_queue config ~keeper_name request =
  let* state =
    Keeper_event_queue_persistence.load_state_result
      ~base_path:config.Workspace.base_path
      ~keeper_name
    |> Result.map_error (fun detail -> Source_queue_validation_failed detail)
  in
  if not (Int64.equal (Keeper_event_queue_state.revision state) request.source_revision)
  then Error (Source_queue_validation_failed "source revision changed")
  else if Keeper_event_queue_state.leases state <> []
  then Error (Source_queue_validation_failed "source lane has an active lease")
  else if Keeper_event_queue_state.transition_outbox state <> []
  then Error (Source_queue_validation_failed "source lane has a pending transition outbox")
  else
    let matching =
      Keeper_event_queue.to_list (Keeper_event_queue_state.pending state)
      |> List.filter (fun source ->
        Keeper_event_queue.stimulus_identity_equal request.source source)
    in
    match matching with
    | [ source ] when source = request.source -> Ok ()
    | [ _ ] -> Error (Source_queue_validation_failed "source snapshot changed")
    | [] -> Error (Source_queue_validation_failed "source is not pending")
    | _ :: _ :: _ ->
      Error (Source_queue_validation_failed "source identity is duplicated")
;;

let operation_of_receipt receipt =
  match receipt.Keeper_paused_work_disposition_receipt.operation with
  | Keeper_paused_work_disposition_receipt.Settle_from_source_terminal operation ->
    Ok operation
  | Keeper_paused_work_disposition_receipt.Resume_owner
  | Keeper_paused_work_disposition_receipt.Transfer_owner _ ->
    Error (Receipt_conflict receipt)
;;

let receipt_matches_request ~keeper_name request receipt =
  match operation_of_receipt receipt with
  | Error _ -> false
  | Ok operation ->
    String.equal receipt.keeper_name keeper_name
    && Int.equal receipt.expected_generation request.owner_nonce
    && String.equal receipt.operator_operation_id request.operator_operation_id
    && operation.source = request.source
    && Int64.equal operation.source_revision request.source_revision
    && Float.equal operation.settled_at request.settled_at
    && operation.source_receipt = request.source_receipt
;;

let create_receipt config ~keeper_name request =
  let* meta = read_meta config keeper_name in
  let* meta = validate_paused_owner request meta in
  let* () = validate_source_queue config ~keeper_name request in
  let operation : Keeper_paused_work_disposition_receipt.source_terminal_operation =
    { source = request.source
    ; source_revision = request.source_revision
    ; settled_at = request.settled_at
    ; source_receipt = request.source_receipt
    }
  in
  Ok
    ({ keeper_name
     ; expected_trace_id = meta.runtime.trace_id
     ; expected_generation = request.owner_nonce
     ; operator_operation_id = request.operator_operation_id
     ; requested_at = Time_compat.now ()
     ; operation =
         Keeper_paused_work_disposition_receipt.Settle_from_source_terminal
           operation
     }
     : Keeper_paused_work_disposition_receipt.t)
;;

let project_receipt config receipt =
  let* operation = operation_of_receipt receipt in
  let source_terminal : Keeper_registry_event_queue.accepted_source_terminal =
    { source = operation.source
    ; source_revision = operation.source_revision
    ; owner_nonce = receipt.Keeper_paused_work_disposition_receipt.expected_generation
    ; operator_operation_id = receipt.operator_operation_id
    ; source_receipt = operation.source_receipt
    }
  in
  let base_path = config.Workspace.base_path in
  let* state =
    Keeper_event_queue_persistence.load_state_result
      ~base_path
      ~keeper_name:receipt.keeper_name
    |> Result.map_error (fun detail -> Committed_settlement_failed detail)
  in
  let* prior =
    Keeper_event_queue_state.accepted_pending_source_terminal_replay
      source_terminal
      state
    |> Result.map_error (fun detail -> Committed_settlement_failed detail)
  in
  match prior with
  | Some prior -> Ok (Keeper_registry_event_queue.Already_settled prior)
  | None ->
    let* current = read_meta config receipt.keeper_name in
    let* () =
      if not (Int.equal current.runtime.nonce receipt.expected_generation)
      then
        Error
          (Durable_owner_nonce_changed
             { expected = receipt.expected_generation
             ; actual = current.runtime.nonce
             })
      else if not (Keeper_id.Trace_id.equal current.runtime.trace_id receipt.expected_trace_id)
      then Error Durable_owner_identity_changed
      else Ok ()
    in
    Keeper_registry_event_queue.settle_pending_from_source_terminal_result
      ~base_path
      receipt.keeper_name
      ~current_owner_nonce:current.runtime.nonce
      ~settled_at:operation.settled_at
      ~source_terminal
    |> Result.map_error (fun detail -> Committed_settlement_failed detail)
;;

let run_owned receipt_lock config ~keeper_name request =
  let* existing =
    Keeper_paused_work_disposition_receipt.load
      config
      ~keeper_name
      ~operator_operation_id:request.operator_operation_id
    |> Result.map_error (fun detail -> Receipt_read_failed detail)
  in
  let* receipt, commit_status =
    match existing with
    | Some receipt when receipt_matches_request ~keeper_name request receipt ->
      Ok (receipt, Already_committed)
    | Some receipt -> Error (Receipt_conflict receipt)
    | None ->
      let* receipt = create_receipt config ~keeper_name request in
      (match
         Keeper_paused_work_disposition_receipt.save_if_absent
           receipt_lock
           config
           receipt
       with
       | Error detail -> Error (Receipt_write_failed detail)
       | Ok Keeper_paused_work_disposition_receipt.Created ->
         Ok (receipt, Committed)
       | Ok (Keeper_paused_work_disposition_receipt.Existing existing)
         when Keeper_paused_work_disposition_receipt.equal existing receipt ->
         Ok (existing, Already_committed)
       | Ok (Keeper_paused_work_disposition_receipt.Existing existing) ->
         Error (Receipt_conflict existing))
  in
  let projection =
    match project_receipt config receipt with
    | Ok settlement -> Applied settlement
    | Error failure -> Committed_followup_failed failure
  in
  Ok (receipt, commit_status, projection)
;;

let settle_pending config ~keeper_name request =
  match validate_request request with
  | Error detail ->
    Error { cause = Invalid_request detail; reservation_release = None }
  | Ok () ->
    (match
       Keeper_lifecycle_reservation.acquire
         ~base_path:config.Workspace.base_path
         ~keeper_name
         ~expected_generation:request.owner_nonce
         ~purpose:Keeper_lifecycle_reservation.Paused_work_disposition
     with
     | Error (Keeper_lifecycle_reservation.Already_reserved owner) ->
       Error
         { cause = Reservation_conflict owner; reservation_release = None }
     | Ok token ->
       (try
          let outcome =
            match
              Keeper_paused_work_disposition_receipt.with_keeper_lock
                config
                ~keeper_name
                (fun receipt_lock ->
                   run_owned receipt_lock config ~keeper_name request)
            with
            | Error detail -> Error (Receipt_lock_failed detail)
            | Ok outcome -> outcome
          in
          let reservation_release = Keeper_lifecycle_reservation.release token in
          (match outcome with
           | Ok (receipt, commit_status, projection) ->
             Ok { receipt; commit_status; projection; reservation_release }
           | Error cause ->
             Error { cause; reservation_release = Some reservation_release })
        with
        | exn ->
          (* fire-and-forget: best-effort release; [exn] is re-raised immediately so a release failure must not mask it. *)
          ignore (Keeper_lifecycle_reservation.release token : _);
          raise exn))
;;
