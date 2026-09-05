type request =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; source_receipt : Keeper_event_queue_state.source_terminal_receipt
  ; operator_operation_id : string
  }

type failure =
  | Invalid_request of string
  | Admission_busy of Keeper_owner.autonomous_block
  | Owner_unavailable of string
  | Reservation_conflict of Keeper_lifecycle_reservation.snapshot
  | Receipt_lock_failed of string
  | Receipt_read_failed of string
  | Receipt_conflict of Keeper_paused_work_disposition_receipt.t
  | Receipt_write_failed of string
  | Durable_meta_read_failed of string
  | Durable_meta_missing
  | Durable_owner_not_paused
  | Durable_owner_identity_changed
  | Source_queue_validation_failed of string
  | Committed_ack_failed of string

type error =
  { cause : failure
  ; reservation_release : Keeper_lifecycle_reservation.release_outcome option
  }

type commit_status =
  | Committed
  | Already_committed

type projection =
  | Applied of Keeper_registry_event_queue.source_ack_result
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
    "invalid Ack_source_terminal request: " ^ detail
  | Admission_busy block ->
    Printf.sprintf
      "keeper_owner_busy: operation=ack_source_terminal %s"
      (Keeper_owner.autonomous_block_to_string block)
  | Owner_unavailable detail ->
    "Ack_source_terminal Keeper owner unavailable: " ^ detail
  | Reservation_conflict owner ->
    "Ack_source_terminal lifecycle reservation conflict: "
    ^ Keeper_lifecycle_reservation.snapshot_to_string owner
  | Receipt_lock_failed detail ->
    "Ack_source_terminal receipt lock failed: " ^ detail
  | Receipt_read_failed detail ->
    "Ack_source_terminal receipt read failed: " ^ detail
  | Receipt_conflict receipt ->
    Printf.sprintf
      "Ack_source_terminal operation ID conflicts with keeper=%s requested_at=%.17g"
      receipt.keeper_name
      receipt.requested_at
  | Receipt_write_failed detail ->
    "Ack_source_terminal receipt write failed: " ^ detail
  | Durable_meta_read_failed detail ->
    "Ack_source_terminal durable metadata read failed: " ^ detail
  | Durable_meta_missing ->
    "Ack_source_terminal durable Keeper metadata is missing"
  | Durable_owner_not_paused ->
    "Ack_source_terminal requires a paused Keeper"
  | Durable_owner_identity_changed ->
    "Ack_source_terminal trace identity changed"
  | Source_queue_validation_failed detail ->
    "Ack_source_terminal source queue validation failed: " ^ detail
  | Committed_ack_failed detail ->
    "Ack_source_terminal committed receipt but source ACK failed: " ^ detail
;;

let error_to_string error =
  let base = failure_to_string error.cause in
  match error.reservation_release with
  | None -> base
  | Some outcome ->
    base
    ^ "; reservation_release="
    ^ Keeper_lifecycle_reservation.release_outcome_to_string outcome
;;

let validate_request request =
  if Int64.compare request.source_incarnation 0L < 0
  then Error "source incarnation must not be negative"
  else if String.equal (String.trim request.source.post_id) ""
  then Error "source post id must not be empty"
  else if String.equal (String.trim request.operator_operation_id) ""
  then Error "operator operation ID must not be empty"
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
  | Keeper_lifecycle_admission.Paused _ -> Ok meta
;;

let validate_source_queue config ~keeper_name request =
  let* state =
    Keeper_event_queue_persistence.load_state_result
      ~base_path:config.Workspace.base_path
      ~keeper_name
    |> Result.map_error (fun detail -> Source_queue_validation_failed detail)
  in
  if Keeper_event_queue_state.transition_outbox state <> []
  then Error (Source_queue_validation_failed "source lane has a pending transition outbox")
  else
    (* Identity and admission revision, not full structural equality: a
       live entry can carry checkpoint retentions the receipt cannot know,
       so the exact-selection comparison would fail against a retained
       entry. *)
    Keeper_event_queue_state.resolve_pending_selection
      ~source_ref:
        (Keeper_event_queue_state.source_snapshot_ref request.source)
      ~source_incarnation:request.source_incarnation
      state
    |> Result.map (fun _ -> ())
    |> Result.map_error (fun detail -> Source_queue_validation_failed detail)
;;

let operation_of_receipt receipt =
  match receipt.Keeper_paused_work_disposition_receipt.operation with
  | Keeper_paused_work_disposition_receipt.Ack_source_terminal operation ->
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
    && String.equal receipt.operator_operation_id request.operator_operation_id
    && operation.source = request.source
    && Int64.equal operation.source_incarnation request.source_incarnation
    && operation.source_receipt = request.source_receipt
;;

let create_receipt config ~keeper_name request =
  let* meta = read_meta config keeper_name in
  let* meta = validate_paused_owner request meta in
  let* () = validate_source_queue config ~keeper_name request in
  let operation : Keeper_paused_work_disposition_receipt.source_terminal_operation =
    { source = request.source
    ; source_incarnation = request.source_incarnation
    ; source_receipt = request.source_receipt
    }
  in
  Ok
    ({ keeper_name
     ; expected_trace_id = meta.runtime.trace_id
     ; operator_operation_id = request.operator_operation_id
     ; requested_at = Time_compat.now ()
     ; operation =
         Keeper_paused_work_disposition_receipt.Ack_source_terminal
           operation
     }
     : Keeper_paused_work_disposition_receipt.t)
;;

let project_receipt config receipt =
  let* operation = operation_of_receipt receipt in
  let source_terminal : Keeper_registry_event_queue.accepted_source_terminal =
    { source = operation.source
    ; source_incarnation = operation.source_incarnation
    ; operator_operation_id = receipt.operator_operation_id
    ; source_receipt = operation.source_receipt
    }
  in
  let base_path = config.Workspace.base_path in
  let* state =
    Keeper_event_queue_persistence.load_state_result
      ~base_path
      ~keeper_name:receipt.keeper_name
    |> Result.map_error (fun detail -> Committed_ack_failed detail)
  in
  let* prior =
    Keeper_event_queue_state.accepted_pending_source_terminal_ack_replay
      source_terminal
      state
    |> Result.map_error (fun detail -> Committed_ack_failed detail)
  in
  match prior with
  | Some prior -> Ok (Keeper_registry_event_queue.Already_acked prior)
  | None ->
    let* current = read_meta config receipt.keeper_name in
    let* () =
      if not (Keeper_id.Trace_id.equal current.runtime.trace_id receipt.expected_trace_id)
      then Error Durable_owner_identity_changed
      else Ok ()
    in
    Keeper_registry_event_queue.ack_pending_source_terminal_result
      ~base_path
      receipt.keeper_name
      ~acked_at:receipt.requested_at
      ~source_terminal
    |> Result.map_error (fun detail -> Committed_ack_failed detail)
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
    | Ok result -> Applied result
    | Error failure -> Committed_followup_failed failure
  in
  Ok (receipt, commit_status, projection)
;;

let ack_pending_under_admission config ~keeper_name request =
  match validate_request request with
  | Error detail ->
    Error { cause = Invalid_request detail; reservation_release = None }
  | Ok () ->
    (match
       Keeper_lifecycle_reservation.acquire
         ~base_path:config.Workspace.base_path
         ~keeper_name
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

let ack_pending config ~keeper_name request =
  match
    Keeper_owner_registry.run_maintenance_if_idle
      ~base_path:config.Workspace.base_path
      ~keeper_name
      (fun () -> ack_pending_under_admission config ~keeper_name request)
  with
  | Ok (`Ran outcome) -> outcome
  | Ok (`Busy block) ->
    Error { cause = Admission_busy block; reservation_release = None }
  | Error error ->
    Error
      { cause =
          Owner_unavailable (Keeper_owner_registry.command_error_to_string error)
      ; reservation_release = None
      }
;;
