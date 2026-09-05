type request =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; continuation_binding : Keeper_paused_work_disposition_receipt.continuation_binding
  ; operator_operation_id : string
  }

type projection_stage =
  | Source_ack
  | Target_enqueue

type failure =
  | Invalid_request of string
  | Admission_busy of Keeper_owner.autonomous_block
  | Owner_unavailable of string
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
  | Source_owner_identity_changed
  | Target_owner_not_active
  | Target_owner_identity_changed
  | Continuation_binding_mismatch
  | Source_queue_validation_failed of string
  | Source_transfer_shutdown_reserved of Keeper_shutdown_types.Operation_id.t
  | Target_transfer_shutdown_reserved of Keeper_shutdown_types.Operation_id.t
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
  | Applied of target_projection
  | Committed_followup_failed of failure

type success =
  { receipt : Keeper_paused_work_disposition_receipt.t
  ; commit_status : commit_status
  ; projection : projection
  ; reservation_release : Keeper_lifecycle_reservation.release_outcome
  }

let ( let* ) = Result.bind

let projection_stage_to_string = function
  | Source_ack -> "source_ack"
  | Target_enqueue -> "target_enqueue"
;;

let failure_to_string = function
  | Invalid_request detail -> "invalid Transfer_owner request: " ^ detail
  | Admission_busy block ->
    Printf.sprintf
      "keeper_owner_busy: operation=transfer_pending %s"
      (Keeper_owner.autonomous_block_to_string block)
  | Owner_unavailable detail -> "Transfer_owner Keeper owner unavailable: " ^ detail
  | Reservation_conflict owner ->
    "Transfer_owner lifecycle reservation conflict: "
    ^ Keeper_lifecycle_reservation.snapshot_to_string owner
  | Receipt_lock_failed detail -> "Transfer_owner receipt lock failed: " ^ detail
  | Receipt_read_failed detail -> "Transfer_owner receipt read failed: " ^ detail
  | Receipt_conflict receipt ->
    Printf.sprintf
      "Transfer_owner operation ID conflicts with keeper=%s requested_at=%.17g"
      receipt.keeper_name
      receipt.requested_at
  | Receipt_write_failed detail -> "Transfer_owner receipt write failed: " ^ detail
  | Durable_meta_read_failed { keeper_name; detail } ->
    Printf.sprintf "Transfer_owner durable metadata read failed keeper=%s: %s" keeper_name detail
  | Durable_meta_missing keeper_name ->
    "Transfer_owner durable Keeper metadata is missing: " ^ keeper_name
  | Source_owner_not_paused -> "Transfer_owner source Keeper must be paused"
  | Source_owner_identity_changed ->
    "Transfer_owner source trace identity changed"
  | Target_owner_not_active -> "Transfer_owner target Keeper must be active"
  | Target_owner_identity_changed ->
    "Transfer_owner target trace identity changed"
  | Continuation_binding_mismatch ->
    "Transfer_owner continuation binding does not match the exact source event"
  | Source_queue_validation_failed detail ->
    "Transfer_owner source queue validation failed: " ^ detail
  | Source_transfer_shutdown_reserved operation_id ->
    Printf.sprintf
      "Transfer_owner source durable intake is shutdown-reserved: operation=%s"
      (Keeper_shutdown_types.Operation_id.to_string operation_id)
  | Target_transfer_shutdown_reserved operation_id ->
    Printf.sprintf
      "Transfer_owner target durable intake is shutdown-reserved: operation=%s"
      (Keeper_shutdown_types.Operation_id.to_string operation_id)
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
  | Some outcome ->
    base
    ^ "; reservation_release="
    ^ Keeper_lifecycle_reservation.release_outcome_to_string outcome
;;

let validate_request ~from_keeper ~to_keeper request =
  if String.equal (String.trim from_keeper) ""
  then Error "source Keeper must not be empty"
  else if String.equal (String.trim to_keeper) ""
  then Error "target Keeper must not be empty"
  else if String.equal from_keeper to_keeper
  then Error "source and target Keepers must differ"
  else if Int64.compare request.source_incarnation 0L < 0
  then Error "source incarnation must not be negative"
  else if String.equal (String.trim request.source.post_id) ""
  then Error "source post id must not be empty"
  else if String.equal (String.trim request.operator_operation_id) ""
  then Error "operator operation ID must not be empty"
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
  | Keeper_lifecycle_admission.Paused _ -> Ok meta
;;

let validate_target_owner request (meta : Keeper_meta_contract.keeper_meta) =
  match
      Keeper_lifecycle_admission.state
        ~paused:meta.paused
        ~latched_reason:meta.latched_reason
    with
    | Keeper_lifecycle_admission.Active -> Ok meta
    | Keeper_lifecycle_admission.Paused _ -> Error Target_owner_not_active
;;

let validate_source_queue config ~from_keeper request =
  let* state =
    Keeper_event_queue_persistence.load_state_result
      ~base_path:config.Workspace.base_path
      ~keeper_name:from_keeper
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

let transfer_of_receipt receipt =
  match receipt.Keeper_paused_work_disposition_receipt.operation with
  | Keeper_paused_work_disposition_receipt.Transfer_owner transfer -> Ok transfer
  | Keeper_paused_work_disposition_receipt.Resume_owner ->
    Error (Receipt_conflict receipt)
  | Keeper_paused_work_disposition_receipt.Ack_source_terminal _ ->
    Error (Receipt_conflict receipt)
;;

let receipt_matches_request ~from_keeper ~to_keeper request receipt =
  match transfer_of_receipt receipt with
  | Error _ -> false
  | Ok transfer ->
    String.equal receipt.keeper_name from_keeper
      && String.equal receipt.operator_operation_id request.operator_operation_id
    && String.equal transfer.from_keeper from_keeper
    && String.equal transfer.to_keeper to_keeper
      && transfer.source = request.source
    && Int64.equal transfer.source_incarnation request.source_incarnation
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
    ; source = request.source
    ; source_incarnation = request.source_incarnation
    ; continuation_binding = request.continuation_binding
    }
  in
  Ok
    ({ keeper_name = from_keeper
     ; expected_trace_id = source_meta.runtime.trace_id
      ; operator_operation_id = request.operator_operation_id
     ; requested_at = Time_compat.now ()
     ; operation = Keeper_paused_work_disposition_receipt.Transfer_owner transfer
     }
     : Keeper_paused_work_disposition_receipt.t)
;;

let accepted_transfer (receipt : Keeper_paused_work_disposition_receipt.t)
      (transfer : Keeper_paused_work_disposition_receipt.transfer_owner)
    : Keeper_registry_event_queue.accepted_transfer =
  { source = transfer.Keeper_paused_work_disposition_receipt.source
  ; source_incarnation = transfer.source_incarnation
  ; operator_operation_id = receipt.operator_operation_id
  ; from_keeper = transfer.from_keeper
  ; to_keeper = transfer.to_keeper
  ; target_trace_id = transfer.target_trace_id
  }
;;

let ack_source ?intake_token config
      (receipt : Keeper_paused_work_disposition_receipt.t) transfer =
  let causal = accepted_transfer receipt transfer in
  let base_path = config.Workspace.base_path in
  let* source_state =
    Keeper_event_queue_persistence.load_state_result
      ~base_path
      ~keeper_name:transfer.from_keeper
    |> Result.map_error (fun detail ->
      Committed_projection_failed { stage = Source_ack; detail })
  in
  let* prior =
    Keeper_event_queue_state.accepted_pending_transfer_replay causal source_state
    |> Result.map_error (fun detail ->
      Committed_projection_failed { stage = Source_ack; detail })
  in
  match prior with
  | Some _ -> Ok ()
  | None ->
    let* current = read_meta config transfer.from_keeper in
    let* () =
      if not (Keeper_id.Trace_id.equal current.runtime.trace_id receipt.expected_trace_id)
      then Error Source_owner_identity_changed
      else Ok ()
    in
    (* The receipt is the durable transfer-acceptance boundary, so its stored
       request time is the sole timestamp for the source ACK. *)
    let* outcome =
      Keeper_registry_event_queue.transfer_pending_accepted_result
        ?intake_token
        ~base_path
        transfer.from_keeper
        ~applied_at:receipt.requested_at
        ~transfer:causal
      |> Result.map_error (function
        | Keeper_registry_event_queue.Transfer_pending_storage_error detail ->
          Committed_projection_failed { stage = Source_ack; detail }
        | Keeper_registry_event_queue.Transfer_pending_shutdown_reserved operation_id ->
          Source_transfer_shutdown_reserved operation_id)
    in
    (match outcome with
     | Keeper_registry_event_queue.Transition_applied _
     | Keeper_registry_event_queue.Transition_already_applied _ -> Ok ()
     | Keeper_registry_event_queue.Transition_committed_followup_failed
         { stage; detail; _ } ->
       let stage =
         match stage with
         | `Checkpoint -> "checkpoint"
         | `Wal_compaction -> "wal_compaction"
         | `Projection -> "projection"
       in
       Error
         (Committed_projection_failed
            { stage = Source_ack
            ; detail =
                Printf.sprintf
                  "source ACK committed but %s follow-up failed: %s"
                  stage
                  detail
            }))
;;

let target_enqueue ?intake_token config receipt transfer =
  let causal = accepted_transfer receipt transfer in
  match
    Keeper_registry_event_queue.project_accepted_transfer_durable_result
      ?intake_token
      ~base_path:config.Workspace.base_path
      transfer.Keeper_paused_work_disposition_receipt.to_keeper
      ~transfer:causal
  with
  | Keeper_registry_event_queue.Transfer_projection_committed -> Ok Enqueued
  | Keeper_registry_event_queue.Transfer_projection_already_committed ->
    Ok Already_present
  | Keeper_registry_event_queue.Transfer_projection_storage_error detail ->
    Error (Committed_projection_failed { stage = Target_enqueue; detail })
  | Keeper_registry_event_queue.Transfer_projection_target_unavailable
      Keeper_registry_event_queue.Transfer_target_trace_changed ->
    Error Target_owner_identity_changed
  | Keeper_registry_event_queue.Transfer_projection_target_unavailable error ->
    Error
      (Committed_projection_failed
         { stage = Target_enqueue
         ; detail = Keeper_registry_event_queue.transfer_target_error_to_string error
         })
  | Keeper_registry_event_queue.Transfer_projection_shutdown_reserved operation_id ->
    Error
      (Committed_projection_failed
         { stage = Target_enqueue
         ; detail =
             Printf.sprintf
               "target Keeper shutdown owns durable intake operation=%s"
               (Keeper_shutdown_types.Operation_id.to_string operation_id)
         })
;;

let receipt_matches_accepted_transfer
      receipt
      (receipt_transfer : Keeper_paused_work_disposition_receipt.transfer_owner)
      (accepted : Keeper_registry_event_queue.accepted_transfer)
  =
  String.equal receipt.Keeper_paused_work_disposition_receipt.keeper_name accepted.from_keeper
  && String.equal receipt.operator_operation_id accepted.operator_operation_id
  && String.equal receipt_transfer.from_keeper accepted.from_keeper
  && String.equal receipt_transfer.to_keeper accepted.to_keeper
  && Keeper_id.Trace_id.equal receipt_transfer.target_trace_id accepted.target_trace_id
  && receipt_transfer.source = accepted.source
  && Int64.equal receipt_transfer.source_incarnation accepted.source_incarnation
;;

let project_committed_target_if_receipted
      ?intake_token
      config
      ~(transfer : Keeper_registry_event_queue.accepted_transfer)
  =
  let* receipt =
    Keeper_paused_work_disposition_receipt.load
      config
      ~keeper_name:transfer.from_keeper
      ~operator_operation_id:transfer.operator_operation_id
    |> Result.map_error (fun detail -> Receipt_read_failed detail)
  in
  match receipt with
  | None -> Ok None
  | Some receipt ->
    let* receipt_transfer = transfer_of_receipt receipt in
    if receipt_matches_accepted_transfer receipt receipt_transfer transfer
    then
      target_enqueue ?intake_token config receipt receipt_transfer
      |> Result.map Option.some
    else Error (Receipt_conflict receipt)
;;

let project_receipt
      ~source_intake_token
      ~target_intake_token
      config
      receipt
  =
  let* transfer = transfer_of_receipt receipt in
  let* () =
    ack_source ~intake_token:source_intake_token config receipt transfer
  in
  let* target_projection =
    target_enqueue ~intake_token:target_intake_token config receipt transfer
  in
  Ok (Applied target_projection)
;;

let run_owned
      receipt_lock
      config
      ~source_intake_token
      ~target_intake_token
      ~from_keeper
      ~to_keeper
      request
  =
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
    match
      project_receipt
        ~source_intake_token
        ~target_intake_token
        config
        receipt
    with
    | Ok projection -> projection
    | Error failure -> Committed_followup_failed failure
  in
  Ok (receipt, commit_status, projection)
;;

let transfer_pending_under_reservation
      config
      ~source_intake_token
      ~target_intake_token
      ~from_keeper
      ~to_keeper
      request
  =
  match
    Keeper_paused_work_disposition_receipt.with_keeper_lock
      config
      ~keeper_name:from_keeper
      (fun receipt_lock ->
         run_owned
           receipt_lock
           config
           ~source_intake_token
           ~target_intake_token
           ~from_keeper
           ~to_keeper
           request)
  with
  | Error detail -> Error (Receipt_lock_failed detail)
  | Ok outcome -> outcome
;;

let transfer_pending_with_reservation config ~from_keeper ~to_keeper request =
  match
    Keeper_lifecycle_reservation.acquire
      ~base_path:config.Workspace.base_path
      ~keeper_name:from_keeper
      ~purpose:Keeper_lifecycle_reservation.Paused_work_disposition
  with
  | Error (Keeper_lifecycle_reservation.Already_reserved owner) ->
    Error
      { cause = Reservation_conflict owner; reservation_release = None }
  | Ok token ->
    (try
       let outcome =
         Keeper_shutdown_intake_fence.run_transfer_intake_if_open
           ~base_path:config.Workspace.base_path
           ~from_keeper
           ~to_keeper
           (fun ~source_intake_token ~target_intake_token ->
              transfer_pending_under_reservation
                config
                ~source_intake_token
                ~target_intake_token
                ~from_keeper
                ~to_keeper
                request)
       in
       let reservation_release = Keeper_lifecycle_reservation.release token in
       (match outcome with
        | Keeper_shutdown_intake_fence.Transfer_intake_committed
            (Ok (receipt, commit_status, projection)) ->
          Ok { receipt; commit_status; projection; reservation_release }
        | Keeper_shutdown_intake_fence.Transfer_intake_committed (Error cause) ->
          Error { cause; reservation_release = Some reservation_release }
        | Keeper_shutdown_intake_fence.Transfer_intake_source_shutdown_reserved operation_id ->
          Error
            { cause = Source_transfer_shutdown_reserved operation_id
            ; reservation_release = Some reservation_release
            }
        | Keeper_shutdown_intake_fence.Transfer_intake_target_shutdown_reserved operation_id ->
          Error
            { cause = Target_transfer_shutdown_reserved operation_id
            ; reservation_release = Some reservation_release
            })
     with
     | exn ->
       (* fire-and-forget: best-effort release; [exn] is re-raised immediately so a release failure must not mask it. *)
       ignore (Keeper_lifecycle_reservation.release token : _);
       raise exn)
;;

let transfer_pending config ~from_keeper ~to_keeper request =
  match validate_request ~from_keeper ~to_keeper request with
  | Error detail ->
    Error { cause = Invalid_request detail; reservation_release = None }
  | Ok () ->
    (match
       Keeper_owner_registry.run_maintenance_if_idle
         ~base_path:config.Workspace.base_path
         ~keeper_name:from_keeper
         (fun () ->
            transfer_pending_with_reservation
              config
              ~from_keeper
              ~to_keeper
              request)
     with
     | Ok (`Busy block) ->
       Error { cause = Admission_busy block; reservation_release = None }
     | Ok (`Ran outcome) -> outcome
     | Error error ->
       Error
         { cause =
             Owner_unavailable (Keeper_owner_registry.command_error_to_string error)
         ; reservation_release = None
         })
;;
