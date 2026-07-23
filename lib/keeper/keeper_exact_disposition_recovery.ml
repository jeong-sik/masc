let ( let* ) = Result.bind

let checkpoint_ref_load_error_label = function
  | Keeper_checkpoint_store.Ref_not_found -> "not_found"
  | Ref_read_failed _ -> "read_failed"
  | Ref_identity_invalid _ -> "identity_invalid"
  | Ref_session_mismatch _ -> "session_mismatch"
  | Ref_lock_failed _ -> "lock_failed"
;;

let current_checkpoint_ref ~base_path ~trace_id =
  let config = Workspace.default_config base_path in
  let session_id = Keeper_id.Trace_id.to_string trace_id in
  let session_dir = Keeper_types_support.keeper_session_dir config session_id in
  match
    Keeper_checkpoint_store.load_oas_with_ref ~session_dir ~session_id
  with
  | Ok (_, reference) -> Ok reference
  | Error error ->
    Error
      (Printf.sprintf
         "exact disposition checkpoint reconciliation failed: %s"
         (checkpoint_ref_load_error_label error))
;;

let prepare_registration_result
      ~base_path
      ~keeper_name
      ~trace_id:_
      ~settled_at
  =
  let* binding =
    Keeper_event_queue_persistence.exact_execution_binding_result
      ~base_path
      ~keeper_name
  in
  let current_checkpoint_ref =
    match binding with
    | Some
        { status =
            ( Keeper_event_queue_persistence.Checkpoint_commit_intent _
            | Keeper_event_queue_persistence.Checkpoint_commit_observed _ )
        ; _
        } ->
      Some (fun disposition_trace_id ->
          current_checkpoint_ref ~base_path ~trace_id:disposition_trace_id)
    | None
    | Some
        { status =
            ( Keeper_event_queue_persistence.Dispatch_uncertain
            | Keeper_event_queue_persistence.Terminal_quarantined _
            | Keeper_event_queue_persistence.Disposition_prepared _ )
        ; _
        } ->
      None
  in
  Keeper_event_queue_persistence.prepare_registration_after_exact_recovery_result
    ~base_path
    ~keeper_name
    ~settled_at
    ~current_checkpoint_ref
    ()
;;
