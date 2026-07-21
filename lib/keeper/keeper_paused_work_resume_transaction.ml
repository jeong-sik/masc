type request =
  { owner_generation : int
  ; operator_operation_id : string
  }

type projection_stage =
  | Durable_meta
  | Registry_meta
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
  | Durable_owner_generation_changed of
      { expected : int
      ; actual : int
      }
  | Durable_owner_identity_changed
  | Durable_owner_not_paused
  | Durable_owner_dead_tombstone
  | Registry_owner_missing
  | Registry_owner_generation_changed of
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
  | Registry_meta -> "registry_meta"
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
  | Durable_owner_generation_changed { expected; actual } ->
    Printf.sprintf
      "Resume_owner durable generation changed: expected %d, actual %d"
      expected
      actual
  | Durable_owner_identity_changed -> "Resume_owner durable trace identity changed"
  | Durable_owner_not_paused -> "Resume_owner requires a durably paused Keeper"
  | Durable_owner_dead_tombstone ->
    "Resume_owner cannot revive a Dead tombstone; use the dead-revival transaction"
  | Registry_owner_missing -> "Resume_owner requires the exact registered Keeper lane"
  | Registry_owner_generation_changed { expected; actual } ->
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
  if request.owner_generation < 0
  then Error "owner generation must not be negative"
  else if String.equal (String.trim request.operator_operation_id) ""
  then Error "operator operation ID must not be empty"
  else Ok ()
;;

let receipt_matches_request ~keeper_name request receipt =
  String.equal receipt.Keeper_paused_work_disposition_receipt.keeper_name keeper_name
  && Int.equal receipt.expected_generation request.owner_generation
  && String.equal receipt.operator_operation_id request.operator_operation_id
  && receipt.operation = Keeper_paused_work_disposition_receipt.Resume_owner
;;

let read_meta config keeper_name =
  Keeper_meta_store.read_meta config keeper_name
  |> Result.map_error (fun detail -> Durable_meta_read_failed detail)
;;

let validate_identity receipt (meta : Keeper_meta_contract.keeper_meta) =
  if not (Int.equal meta.runtime.generation receipt.expected_generation)
  then
    Error
      (Durable_owner_generation_changed
         { expected = receipt.expected_generation; actual = meta.runtime.generation })
  else if not (Keeper_id.Trace_id.equal meta.runtime.trace_id receipt.expected_trace_id)
  then Error Durable_owner_identity_changed
  else Ok ()
;;

let paused_meta receipt (meta : Keeper_meta_contract.keeper_meta) =
  match
    Keeper_lifecycle_admission.state
      ~paused:meta.paused
      ~latched_reason:meta.latched_reason
  with
  | Keeper_lifecycle_admission.Dead_tombstone -> Error Durable_owner_dead_tombstone
  | Keeper_lifecycle_admission.Active -> Error Durable_owner_not_paused
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
  | Some entry when entry.meta.runtime.generation <> receipt.expected_generation ->
    Error
      (Registry_owner_generation_changed
         { expected = receipt.expected_generation
         ; actual = entry.meta.runtime.generation
         })
  | Some entry
    when not
           (Keeper_id.Trace_id.equal
              entry.meta.runtime.trace_id
              receipt.expected_trace_id) ->
    Error Registry_owner_identity_changed
  | Some entry -> Ok (Some entry)
;;

let update_registry_meta token entry committed =
  match
    Keeper_registry.update_entry_exact_for_lifecycle token entry (fun current ->
      { current with meta = committed })
  with
  | Keeper_registry.Exact_updated -> Ok ()
  | Keeper_registry.Exact_update_missing -> Error "registered lane disappeared"
  | Keeper_registry.Exact_update_replaced -> Error "registered lane was replaced"
  | Keeper_registry.Exact_update_invalid error ->
    Error (Keeper_registry.registry_entry_validation_error_to_string error)
;;

let project_registry token entry committed =
  let* () =
    update_registry_meta token entry committed
    |> Result.map_error (fun detail -> Projection_failed { stage = Registry_meta; detail })
  in
  let* phase =
    match entry.phase with
    | Keeper_state_machine.Paused ->
      Keeper_registry.dispatch_event_exact_for_lifecycle
        token
        entry
        Keeper_state_machine.Operator_resume
      |> Result.map (fun transition -> transition.new_phase)
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

let project_receipt token config receipt =
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
      let* paused = paused_meta receipt current in
      let candidate =
        { (Keeper_meta_contract.mark_resumed paused) with
          updated_at = Keeper_meta_contract.now_iso ()
        }
      in
      let* () =
        Keeper_meta_store.write_meta_with_merge_for_lifecycle
          token
          ~merge:Keeper_meta_merge.monotonic_usage_counters
          config
          candidate
        |> Result.map_error (fun detail ->
          Projection_failed { stage = Durable_meta; detail })
      in
      (match read_meta config receipt.keeper_name with
       | Error _ as error -> error
       | Ok None -> Error Durable_meta_missing
       | Ok (Some committed) ->
         let* () = validate_identity receipt committed in
         if committed.paused
         then
           Error
             (Projection_failed
                { stage = Durable_meta
                ; detail = "durable pause bit remained set after commit"
                })
         else Ok committed)
    else Ok current
  in
  match entry with
  | None -> Error Registry_owner_missing
  | Some entry -> project_registry token entry committed
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
    ; expected_generation = request.owner_generation
    ; operator_operation_id = request.operator_operation_id
    ; requested_at = Time_compat.now ()
    ; operation = Keeper_paused_work_disposition_receipt.Resume_owner
    }
  in
  let* _ = paused_meta receipt current in
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
         ~expected_generation:request.owner_generation
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
