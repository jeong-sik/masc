type request =
  { source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; owner_generation : int
  ; target_generation : int
  ; continuation_binding : Keeper_paused_work_disposition_receipt.continuation_binding
  ; operator_operation_id : string
  ; settled_at : float
  }

type projection_stage =
  | Source_settlement
  | Target_enqueue

type failure =
  | Invalid_request of string
  | Reservation_conflict of Keeper_lifecycle_reservation.snapshot
  | Receipt_lock_failed of string
  | Receipt_read_failed of string
  | Receipt_conflict of Keeper_paused_work_disposition_receipt.t
  | Receipt_write_failed of string
  | Durable_meta_read_failed of
      { keeper_name : string
      ; detail : string
      }
  | Durable_meta_missing of string
  | Source_owner_not_paused
  | Source_owner_dead_tombstone
  | Source_owner_generation_changed of
      { expected : int
      ; actual : int
      }
  | Source_owner_identity_changed
  | Target_owner_not_active
  | Target_owner_generation_changed of
      { expected : int
      ; actual : int
      }
  | Continuation_binding_mismatch
  | Source_queue_validation_failed of string
  | Committed_projection_failed of
      { stage : projection_stage
      ; detail : string
      }

type error =
  { cause : failure
  ; reservation_release : Keeper_lifecycle_reservation.release_outcome option
  }

type commit_status =
  | Committed
  | Already_committed

type target_projection =
  | Enqueued
  | Already_present

type projection =
  | Applied of
      { source_settlement : Keeper_registry_event_queue.settle_result
      ; target_projection : target_projection
      }
  | Committed_followup_failed of failure

type success =
  { receipt : Keeper_paused_work_disposition_receipt.t
  ; commit_status : commit_status
  ; projection : projection
  ; reservation_release : Keeper_lifecycle_reservation.release_outcome
  }

let ( let* ) = Result.bind

let projection_stage_to_string = function
  | Source_settlement -> "source_settlement"
  | Target_enqueue -> "target_enqueue"
;;

let failure_to_string = function
  | Invalid_request detail -> "invalid Transfer_owner request: " ^ detail
  | Reservation_conflict owner ->
    "Transfer_owner lifecycle reservation conflict: "
    ^ Keeper_lifecycle_reservation.snapshot_to_string owner
  | Receipt_lock_failed detail -> "Transfer_owner receipt lock failed: " ^ detail
  | Receipt_read_failed detail -> "Transfer_owner receipt read failed: " ^ detail
  | Receipt_conflict receipt ->
    Printf.sprintf
      "Transfer_owner operation ID conflicts with keeper=%s generation=%d requested_at=%.17g"
      receipt.keeper_name
      receipt.expected_generation
      receipt.requested_at
  | Receipt_write_failed detail -> "Transfer_owner receipt write failed: " ^ detail
  | Durable_meta_read_failed { keeper_name; detail } ->
    Printf.sprintf "Transfer_owner durable metadata read failed keeper=%s: %s" keeper_name detail
  | Durable_meta_missing keeper_name ->
    "Transfer_owner durable Keeper metadata is missing: " ^ keeper_name
  | Source_owner_not_paused -> "Transfer_owner source Keeper must be paused"
  | Source_owner_dead_tombstone ->
    "Transfer_owner cannot use a Dead source tombstone"
  | Source_owner_generation_changed { expected; actual } ->
    Printf.sprintf
      "Transfer_owner source generation changed: expected %d, actual %d"
      expected
      actual
  | Source_owner_identity_changed ->
    "Transfer_owner source trace identity changed"
  | Target_owner_not_active -> "Transfer_owner target Keeper must be active"
  | Target_owner_generation_changed { expected; actual } ->
    Printf.sprintf
      "Transfer_owner target generation changed: expected %d, actual %d"
      expected
      actual
  | Continuation_binding_mismatch ->
    "Transfer_owner continuation binding does not match the exact source event"
  | Source_queue_validation_failed detail ->
    "Transfer_owner source queue validation failed: " ^ detail
  | Committed_projection_failed { stage; detail } ->
    Printf.sprintf
      "Transfer_owner committed receipt but %s projection failed: %s"
      (projection_stage_to_string stage)
      detail
;;

let error_to_string error =
  let base = failure_to_string error.cause in
  match error.reservation_release with
  | None -> base
  | Some Keeper_lifecycle_reservation.Released -> base ^ "; reservation_release=released"
  | Some Keeper_lifecycle_reservation.Release_missing ->
    base ^ "; reservation_release=release_missing"
  | Some (Keeper_lifecycle_reservation.Release_not_owner owner) ->
    base
    ^ "; reservation_release=release_not_owner: "
    ^ Keeper_lifecycle_reservation.snapshot_to_string owner
;;

let validate_request ~from_keeper ~to_keeper request =
  if String.equal (String.trim from_keeper) ""
  then Error "source Keeper must not be empty"
  else if String.equal (String.trim to_keeper) ""
  then Error "target Keeper must not be empty"
  else if String.equal from_keeper to_keeper
  then Error "source and target Keepers must differ"
  else if request.owner_generation < 0
  then Error "source owner generation must not be negative"
  else if request.target_generation < 0
  then Error "target owner generation must not be negative"
  else if Int64.compare request.source_revision 0L < 0
  then Error "source revision must not be negative"
  else if String.equal (String.trim request.source.post_id) ""
  then Error "source post id must not be empty"
  else if String.equal (String.trim request.operator_operation_id) ""
  then Error "operator operation ID must not be empty"
  else if not (Float.is_finite request.settled_at)
  then Error "settlement time must be finite"
  else if
    request.continuation_binding
    <> Keeper_paused_work_disposition_receipt.continuation_binding_of_source
         request.source
  then Error "continuation binding does not match source"
  else Ok ()
;;

let read_meta config keeper_name =
  match Keeper_meta_store.read_meta config keeper_name with
  | Error detail -> Error (Durable_meta_read_failed { keeper_name; detail })
  | Ok None -> Error (Durable_meta_missing keeper_name)
  | Ok (Some meta) -> Ok meta
;;

let validate_source_owner request (meta : Keeper_meta_contract.keeper_meta) =
  match
    Keeper_lifecycle_admission.state
      ~paused:meta.paused
      ~latched_reason:meta.latched_reason
  with
  | Keeper_lifecycle_admission.Active -> Error Source_owner_not_paused
  | Keeper_lifecycle_admission.Dead_tombstone -> Error Source_owner_dead_tombstone
  | Keeper_lifecycle_admission.Paused _ ->
    if Int.equal meta.runtime.generation request.owner_generation
    then Ok meta
    else
      Error
        (Source_owner_generation_changed
           { expected = request.owner_generation; actual = meta.runtime.generation })
;;

let validate_target_owner request (meta : Keeper_meta_contract.keeper_meta) =
  if not (Int.equal meta.runtime.generation request.target_generation)
  then
    Error
      (Target_owner_generation_changed
         { expected = request.target_generation; actual = meta.runtime.generation })
  else
    match
      Keeper_lifecycle_admission.state
        ~paused:meta.paused
        ~latched_reason:meta.latched_reason
    with
    | Keeper_lifecycle_admission.Active -> Ok meta
    | Keeper_lifecycle_admission.Paused _
    | Keeper_lifecycle_admission.Dead_tombstone -> Error Target_owner_not_active
;;

let validate_source_queue config ~from_keeper request =
  let* state =
    Keeper_event_queue_persistence.load_state_result
      ~base_path:config.Workspace.base_path
      ~keeper_name:from_keeper
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

let transfer_of_receipt receipt =
  match receipt.Keeper_paused_work_disposition_receipt.operation with
  | Keeper_paused_work_disposition_receipt.Transfer_owner transfer -> Ok transfer
  | Keeper_paused_work_disposition_receipt.Resume_owner ->
    Error (Receipt_conflict receipt)
;;

let receipt_matches_request ~from_keeper ~to_keeper request receipt =
  match transfer_of_receipt receipt with
  | Error _ -> false
  | Ok transfer ->
    String.equal receipt.keeper_name from_keeper
    && Int.equal receipt.expected_generation request.owner_generation
    && String.equal receipt.operator_operation_id request.operator_operation_id
    && String.equal transfer.from_keeper from_keeper
    && String.equal transfer.to_keeper to_keeper
    && Int.equal transfer.target_generation request.target_generation
    && transfer.source = request.source
    && Int64.equal transfer.source_revision request.source_revision
    && Float.equal transfer.settled_at request.settled_at
    && transfer.continuation_binding = request.continuation_binding
;;

let create_receipt config ~from_keeper ~to_keeper request =
  let* source_meta = read_meta config from_keeper in
  let* source_meta = validate_source_owner request source_meta in
  let* target_meta = read_meta config to_keeper in
  let* target_meta = validate_target_owner request target_meta in
  let* () = validate_source_queue config ~from_keeper request in
  let transfer : Keeper_paused_work_disposition_receipt.transfer_owner =
    { from_keeper
    ; to_keeper
    ; target_trace_id = target_meta.runtime.trace_id
    ; target_generation = request.target_generation
    ; source = request.source
    ; source_revision = request.source_revision
    ; settled_at = request.settled_at
    ; continuation_binding = request.continuation_binding
    }
  in
  Ok
    ({ keeper_name = from_keeper
     ; expected_trace_id = source_meta.runtime.trace_id
     ; expected_generation = request.owner_generation
     ; operator_operation_id = request.operator_operation_id
     ; requested_at = Time_compat.now ()
     ; operation = Keeper_paused_work_disposition_receipt.Transfer_owner transfer
     }
     : Keeper_paused_work_disposition_receipt.t)
;;

let source_settlement config receipt transfer =
  let causal : Keeper_registry_event_queue.accepted_transfer =
    { source = transfer.Keeper_paused_work_disposition_receipt.source
    ; source_revision = transfer.source_revision
    ; owner_generation = receipt.Keeper_paused_work_disposition_receipt.expected_generation
    ; operator_operation_id = receipt.operator_operation_id
    ; from_keeper = transfer.from_keeper
    ; to_keeper = transfer.to_keeper
    }
  in
  let base_path = config.Workspace.base_path in
  let* source_state =
    Keeper_event_queue_persistence.load_state_result
      ~base_path
      ~keeper_name:transfer.from_keeper
    |> Result.map_error (fun detail ->
      Committed_projection_failed { stage = Source_settlement; detail })
  in
  let* prior =
    Keeper_event_queue_state.accepted_pending_transfer_replay causal source_state
    |> Result.map_error (fun detail ->
      Committed_projection_failed { stage = Source_settlement; detail })
  in
  match prior with
  | Some prior -> Ok (Keeper_registry_event_queue.Already_settled prior)
  | None ->
    let* current = read_meta config transfer.from_keeper in
    let* () =
      if not (Int.equal current.runtime.generation receipt.expected_generation)
      then
        Error
          (Source_owner_generation_changed
             { expected = receipt.expected_generation
             ; actual = current.runtime.generation
             })
      else if not (Keeper_id.Trace_id.equal current.runtime.trace_id receipt.expected_trace_id)
      then Error Source_owner_identity_changed
      else Ok ()
    in
    Keeper_registry_event_queue.transfer_pending_accepted_result
      ~base_path
      transfer.from_keeper
      ~current_owner_generation:current.runtime.generation
      ~settled_at:transfer.settled_at
      ~transfer:causal
    |> Result.map_error (fun detail ->
      Committed_projection_failed { stage = Source_settlement; detail })
;;

let validate_committed_target config transfer =
  let* meta = read_meta config transfer.Keeper_paused_work_disposition_receipt.to_keeper in
  if not (Int.equal meta.runtime.generation transfer.target_generation)
  then
    Error
      (Target_owner_generation_changed
         { expected = transfer.target_generation; actual = meta.runtime.generation })
  else if not (Keeper_id.Trace_id.equal meta.runtime.trace_id transfer.target_trace_id)
  then
    Error
      (Committed_projection_failed
         { stage = Target_enqueue; detail = "target trace identity changed" })
  else Ok ()
;;

let target_enqueue config transfer =
  let* () = validate_committed_target config transfer in
  match
    Keeper_registry_event_queue.enqueue_exact_stimulus_durable_result
      ~base_path:config.Workspace.base_path
      transfer.Keeper_paused_work_disposition_receipt.to_keeper
      transfer.source
  with
  | Keeper_registry_event_queue.Stimulus_enqueued -> Ok Enqueued
  | Keeper_registry_event_queue.Stimulus_already_present -> Ok Already_present
  | Keeper_registry_event_queue.Stimulus_storage_error detail ->
    Error (Committed_projection_failed { stage = Target_enqueue; detail })
;;

let project_receipt config receipt =
  let* transfer = transfer_of_receipt receipt in
  let* source_settlement = source_settlement config receipt transfer in
  let* target_projection = target_enqueue config transfer in
  Ok (Applied { source_settlement; target_projection })
;;

let run_owned receipt_lock config ~from_keeper ~to_keeper request =
  let* existing =
    Keeper_paused_work_disposition_receipt.load
      config
      ~keeper_name:from_keeper
      ~operator_operation_id:request.operator_operation_id
    |> Result.map_error (fun detail -> Receipt_read_failed detail)
  in
  let* receipt, commit_status =
    match existing with
    | Some receipt
      when receipt_matches_request ~from_keeper ~to_keeper request receipt ->
      Ok (receipt, Already_committed)
    | Some receipt -> Error (Receipt_conflict receipt)
    | None ->
      let* receipt = create_receipt config ~from_keeper ~to_keeper request in
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
    | Ok projection -> projection
    | Error failure -> Committed_followup_failed failure
  in
  Ok (receipt, commit_status, projection)
;;

let transfer_pending config ~from_keeper ~to_keeper request =
  match validate_request ~from_keeper ~to_keeper request with
  | Error detail ->
    Error { cause = Invalid_request detail; reservation_release = None }
  | Ok () ->
    (match
       Keeper_lifecycle_reservation.acquire
         ~base_path:config.Workspace.base_path
         ~keeper_name:from_keeper
         ~expected_generation:request.owner_generation
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
                ~keeper_name:from_keeper
                (fun receipt_lock ->
                   run_owned receipt_lock config ~from_keeper ~to_keeper request)
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
          ignore (Keeper_lifecycle_reservation.release token : _);
          raise exn))
;;
