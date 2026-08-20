type request =
  { owner_nonce : int
  ; operator_operation_id : string
  }

type projection_stage =
  | Durable_meta
  | Registry_transition

type failure =
  | Invalid_request of string
  | Reservation_conflict of Keeper_lifecycle_reservation.snapshot
  | Receipt_lock_failed of string
  | Receipt_read_failed of string
  | Receipt_conflict of Keeper_paused_work_disposition_receipt.t
  | Receipt_write_failed of string
  | Durable_meta_read_failed of string
  | Durable_meta_missing
  | Durable_owner_nonce_changed of
      { expected : int
      ; actual : int
      }
  | Durable_owner_identity_changed
  | Durable_owner_not_paused
  | Durable_owner_dead_tombstone
  | Durable_owner_transcript_reset_required
  | Registry_owner_missing
  | Registry_owner_nonce_changed of
      { expected : int
      ; actual : int
      }
  | Registry_owner_identity_changed
  | Registry_owner_not_paused of Keeper_state_machine.phase
  | Projection_failed of
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

type projection =
  | Applied of Keeper_state_machine.phase
  | Committed_followup_failed of failure

type success =
  { receipt : Keeper_paused_work_disposition_receipt.t
  ; commit_status : commit_status
  ; projection : projection
  ; reservation_release : Keeper_lifecycle_reservation.release_outcome
  }

let ( let* ) = Result.bind

let projection_stage_to_string = function
  | Durable_meta -> "durable_meta"
  | Registry_transition -> "registry_transition"
;;

let failure_to_string = function
  | Invalid_request detail -> "invalid Resume_owner request: " ^ detail
  | Reservation_conflict owner ->
    "Resume_owner lifecycle reservation conflict: "
    ^ Keeper_lifecycle_reservation.snapshot_to_string owner
  | Receipt_lock_failed detail -> "Resume_owner receipt lock failed: " ^ detail
  | Receipt_read_failed detail -> "Resume_owner receipt read failed: " ^ detail
  | Receipt_conflict receipt ->
    Printf.sprintf
      "Resume_owner operation ID conflicts with keeper=%s generation=%d requested_at=%.17g"
      receipt.keeper_name
      receipt.expected_generation
      receipt.requested_at
  | Receipt_write_failed detail -> "Resume_owner receipt write failed: " ^ detail
  | Durable_meta_read_failed detail -> "Resume_owner durable meta read failed: " ^ detail
  | Durable_meta_missing -> "Resume_owner durable Keeper metadata is missing"
  | Durable_owner_nonce_changed { expected; actual } ->
    Printf.sprintf
      "Resume_owner durable generation changed: expected %d, actual %d"
      expected
      actual
  | Durable_owner_identity_changed -> "Resume_owner durable trace identity changed"
  | Durable_owner_not_paused -> "Resume_owner requires a durably paused Keeper"
  | Durable_owner_dead_tombstone ->
    "Resume_owner cannot revive a Dead tombstone; use the dead-revival transaction"
  | Durable_owner_transcript_reset_required ->
    "Resume_owner cannot replay a structurally corrupted checkpoint; reset the \
     Keeper checkpoint first"
  | Registry_owner_missing -> "Resume_owner requires the exact registered Keeper lane"
  | Registry_owner_nonce_changed { expected; actual } ->
    Printf.sprintf
      "Resume_owner registry generation changed: expected %d, actual %d"
      expected
      actual
  | Registry_owner_identity_changed -> "Resume_owner registry trace identity changed"
  | Registry_owner_not_paused phase ->
    Printf.sprintf
      "Resume_owner requires a paused registry lane, actual phase=%s"
      (Keeper_state_machine.phase_to_string phase)
  | Projection_failed { stage; detail } ->
    Printf.sprintf
      "Resume_owner committed receipt but %s projection failed: %s"
      (projection_stage_to_string stage)
      detail
;;

let error_to_string error =
  let base = failure_to_string error.cause in
  match error.reservation_release with
  | None -> base
  | Some release ->
    let release =
      match release with
      | Keeper_lifecycle_reservation.Released -> "released"
      | Keeper_lifecycle_reservation.Release_missing -> "release_missing"
      | Keeper_lifecycle_reservation.Release_not_owner owner ->
        "release_not_owner: " ^ Keeper_lifecycle_reservation.snapshot_to_string owner
    in
    base ^ "; reservation_release=" ^ release
;;

let validate_request request =
  if request.owner_nonce < 0
  then Error "owner generation must not be negative"
  else if String.equal (String.trim request.operator_operation_id) ""
  then Error "operator operation ID must not be empty"
  else Ok ()
;;

let receipt_matches_request ~keeper_name request receipt =
  String.equal receipt.Keeper_paused_work_disposition_receipt.keeper_name keeper_name
  && Int.equal receipt.expected_generation request.owner_nonce
  && String.equal receipt.operator_operation_id request.operator_operation_id
  && receipt.operation = Keeper_paused_work_disposition_receipt.Resume_owner
;;

let read_meta config keeper_name =
  match
    Keeper_owner_registry.get
      ~base_path:config.Workspace.base_path
      ~keeper_name
  with
  | Error error ->
    Error
      (Durable_meta_read_failed
         (Keeper_owner_registry.lookup_error_to_string error))
  | Ok owner ->
    (match Keeper_owner.exact_projection owner with
     | Ok projection -> Ok projection.meta
     | Error error ->
       Error
         (Durable_meta_read_failed (Keeper_owner.error_to_string error)))
;;

let validate_identity (receipt : Keeper_paused_work_disposition_receipt.t)
      (meta : Keeper_meta_contract.keeper_meta) =
  if not (Int.equal meta.runtime.nonce receipt.expected_generation)
  then
    Error
      (Durable_owner_nonce_changed
         { expected = receipt.expected_generation; actual = meta.runtime.nonce })
  else if not (Keeper_id.Trace_id.equal meta.runtime.trace_id receipt.expected_trace_id)
  then Error Durable_owner_identity_changed
  else Ok ()
;;

type transcript_recovery =
  | Transcript_already_dispatchable
  | Transcript_closed_open_tail of Agent_core.Types.message list
  | Transcript_unrecoverable

(* Downgrade to Operator_paused instead of clearing outright: the keeper stays
   paused and the generic resume path below still owns that transition. Only the
   classification changes, from "cannot replay" to "an operator stopped this". *)
let downgraded_transcript_latch (meta : Keeper_meta_contract.keeper_meta) =
  { meta with
    Keeper_meta_contract.latched_reason =
      Some
        (Keeper_latched_reason.Operator_paused
           { operator_actor = Keeper_latched_reason.operator_actor_grpc_directive })
  }
;;

(* The latch records that the transcript was broken when it was written, not
   that it is broken now. A keeper whose checkpoint has since become
   dispatchable is held by a stale record, so re-read the checkpoint and let its
   current structure decide.

   Two shapes clear it. A transcript that already validates needs nothing. A
   transcript whose only defect is the open ToolUse tail that checkpoint
   persistence preserves on purpose is closed by [close_open_tail], which
   appends one typed ToolResult per unresolved id recording that the call was
   issued and no result was observed. Anything that fails to parse keeps
   latching — that is the contract [close_open_tail] documents, and this does
   not override it. *)
(* The decision, with no I/O in it: read the current messages and say what the
   latch is still worth. Kept separate so the three outcomes are testable
   without seeding a checkpoint on disk. *)
let classify_transcript messages =
  match Keeper_compaction_unit.validate_provider_transcript messages with
  | Ok () -> Transcript_already_dispatchable
  | Error _ ->
    (match Keeper_compaction_unit.close_open_tail messages with
     | Error _ -> Transcript_unrecoverable
     | Ok closure -> Transcript_closed_open_tail closure.Keeper_compaction_unit.messages)
;;

let recover_transcript_latch config (meta : Keeper_meta_contract.keeper_meta) =
  let session_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let session_dir = Keeper_fs.keeper_session_dir config session_id in
  match Keeper_checkpoint_store.load_agent_core_with_ref ~session_dir ~session_id with
  | Error _ -> Error Durable_owner_transcript_reset_required
  | Ok (checkpoint, source_ref) ->
    (match classify_transcript checkpoint.Agent_core.Checkpoint.messages with
     | Transcript_unrecoverable -> Error Durable_owner_transcript_reset_required
     | Transcript_already_dispatchable -> Ok (downgraded_transcript_latch meta)
     | Transcript_closed_open_tail messages ->
       (match
          Keeper_checkpoint_store.save_agent_core_if_source
            ~session_dir
            ~expected_source_ref:source_ref
            { checkpoint with Agent_core.Checkpoint.messages = messages }
        with
        | Keeper_checkpoint_store.Not_installed _ ->
          Error Durable_owner_transcript_reset_required
        | Keeper_checkpoint_store.Installed _ -> Ok (downgraded_transcript_latch meta)))
;;

let paused_meta config receipt (meta : Keeper_meta_contract.keeper_meta) =
  match
    Keeper_lifecycle_admission.state
      ~paused:meta.paused
      ~latched_reason:meta.latched_reason
  with
  | Keeper_lifecycle_admission.Dead_tombstone -> Error Durable_owner_dead_tombstone
  | Keeper_lifecycle_admission.Active -> Error Durable_owner_not_paused
  | Keeper_lifecycle_admission.Paused
      (Keeper_lifecycle_admission.Classified
        Keeper_latched_reason.Transcript_corruption_reset_required) ->
    let* recovered = recover_transcript_latch config meta in
    let* () = validate_identity receipt recovered in
    Ok recovered
  | Keeper_lifecycle_admission.Paused _ ->
    let* () = validate_identity receipt meta in
    Ok meta
;;

let registered_owner_opt config receipt =
  match
    Keeper_registry.get
      ~base_path:config.Workspace.base_path
      receipt.Keeper_paused_work_disposition_receipt.keeper_name
  with
  | None -> Ok None
  | Some entry when entry.meta.runtime.nonce <> receipt.expected_generation ->
    Error
      (Registry_owner_nonce_changed
         { expected = receipt.expected_generation
         ; actual = entry.meta.runtime.nonce
         })
  | Some entry
    when not
           (Keeper_id.Trace_id.equal
              entry.meta.runtime.trace_id
              receipt.expected_trace_id) ->
    Error Registry_owner_identity_changed
  | Some entry -> Ok (Some entry)
;;

let project_registry token (entry : Keeper_registry.registry_entry) =
  let* phase =
    match entry.phase with
    | Keeper_state_machine.Paused ->
      Keeper_registry.dispatch_event_exact_for_lifecycle
        token
        entry
        Keeper_state_machine.Operator_resume
      |> Result.map (fun (transition : Keeper_state_machine.transition_result) ->
           transition.new_phase)
      |> Result.map_error (fun error ->
        Projection_failed
          { stage = Registry_transition
          ; detail = Keeper_state_machine.transition_error_to_string error
          })
    | phase -> Ok phase
  in
  if not (Keeper_state_machine.is_terminal phase)
  then Atomic.set entry.fiber_wakeup true;
  Ok phase
;;

let project_receipt token config (receipt : Keeper_paused_work_disposition_receipt.t) =
  let* current = read_meta config receipt.keeper_name in
  let* current =
    match current with
    | None -> Error Durable_meta_missing
    | Some current ->
      let* () = validate_identity receipt current in
      Ok current
  in
  let* entry = registered_owner_opt config receipt in
  let* committed =
    if current.paused
    then
      let* _paused = paused_meta config receipt current in
      let* committed =
        match
          Keeper_owner_registry.apply_meta
            ~lifecycle_token:token
            ~base_path:config.base_path
            ~keeper_name:receipt.keeper_name
            (Keeper_owner_reducer.Resume
               { updated_at = Keeper_meta_contract.now_iso () })
        with
        | Ok (Some committed) -> Ok committed
        | Ok None -> Error Durable_meta_missing
        | Error error ->
          Error
            (Projection_failed
               { stage = Durable_meta
               ; detail = Keeper_owner_registry.command_error_to_string error
               })
      in
      let* () = validate_identity receipt committed in
      if committed.paused
      then
        Error
          (Projection_failed
             { stage = Durable_meta
             ; detail = "durable pause bit remained set after commit"
             })
      else Ok committed
    else Ok current
  in
  match entry with
  | None -> Error Registry_owner_missing
  | Some entry -> project_registry token entry
;;

let create_receipt config ~keeper_name request =
  let* current = read_meta config keeper_name in
  let* current =
    match current with
    | None -> Error Durable_meta_missing
    | Some current -> Ok current
  in
  let receipt : Keeper_paused_work_disposition_receipt.t =
    { keeper_name
    ; expected_trace_id = current.runtime.trace_id
    ; expected_generation = request.owner_nonce
    ; operator_operation_id = request.operator_operation_id
    ; requested_at = Time_compat.now ()
    ; operation = Keeper_paused_work_disposition_receipt.Resume_owner
    }
  in
  let* _ = paused_meta config receipt current in
  let* entry = registered_owner_opt config receipt in
  match entry with
  | None -> Ok receipt
  | Some entry when entry.phase = Keeper_state_machine.Paused -> Ok receipt
  | Some entry -> Error (Registry_owner_not_paused entry.phase)
;;

let run_owned receipt_lock token config ~keeper_name request =
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
       | Ok Created -> Ok (receipt, Committed)
       | Ok (Existing existing)
         when Keeper_paused_work_disposition_receipt.equal existing receipt ->
         Ok (existing, Already_committed)
       | Ok (Existing existing) -> Error (Receipt_conflict existing))
  in
  let projection =
    match project_receipt token config receipt with
    | Ok phase -> Applied phase
    | Error failure -> Committed_followup_failed failure
  in
  Ok (receipt, commit_status, projection)
;;

let resume config ~keeper_name request =
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
       Error { cause = Reservation_conflict owner; reservation_release = None }
     | Ok token ->
       (try
          let outcome =
            match
              Keeper_paused_work_disposition_receipt.with_keeper_lock
                config
                ~keeper_name
                (fun receipt_lock ->
                   run_owned receipt_lock token config ~keeper_name request)
            with
            | Error detail -> Error (Receipt_lock_failed detail)
            | Ok outcome -> outcome
          in
          let reservation_release = Keeper_lifecycle_reservation.release token in
          (match outcome with
           | Ok (receipt, commit_status, projection) ->
             Ok { receipt; commit_status; projection; reservation_release }
           | Error cause -> Error { cause; reservation_release = Some reservation_release })
        with
        | exn ->
          (* fire-and-forget: best-effort release; [exn] is re-raised immediately so a release failure must not mask it. *)
          ignore (Keeper_lifecycle_reservation.release token : _);
          raise exn))
;;
