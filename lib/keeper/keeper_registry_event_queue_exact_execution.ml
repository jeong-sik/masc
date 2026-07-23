module Make (Publish : sig
    val publish_pending : base_path:string -> string -> Keeper_event_queue.t -> unit
  end) =
struct
  type exact_execution_terminal_cause = Keeper_event_queue_persistence.exact_execution_terminal_cause =
    | Execution_failed_after_dispatch
    | Attempt_already_started
    | Execution_cancelled_after_dispatch
    | Execution_provenance_mismatch
    | Domain_invalid_output
    | Invalid_structural_evidence
    | Invalid_structural_source_after_dispatch
    | Commit_admission_unavailable
    | Lifecycle_transition_failed_after_dispatch
    | Checkpoint_source_changed
    | Checkpoint_persistence_failed
    | Terminal_persistence_failed
  
  type exact_execution_terminal = Keeper_event_queue_persistence.exact_execution_terminal =
    { cause : exact_execution_terminal_cause
    ; slot_id : string
    ; call_id : string
    }

  type exact_source_action = Keeper_event_queue_persistence.exact_source_action =
    | Consume_source
    | Resume_source
    | Replace_with_successor of Keeper_event_queue.stimulus

  type exact_source_outcome = Keeper_event_queue_persistence.exact_source_outcome =
    | Terminal of exact_execution_terminal_cause
    | Checkpoint_committed of
        { intended_ref : Keeper_checkpoint_ref.t
        }

  type exact_source_disposition = Keeper_event_queue_persistence.exact_source_disposition

  type exact_execution_lease_status = Keeper_event_queue_persistence.exact_execution_lease_status =
    | Dispatch_uncertain
    | Terminal_quarantined of exact_execution_terminal_cause
    | Disposition_prepared of exact_source_disposition
    | Checkpoint_commit_intent of exact_source_disposition
    | Checkpoint_commit_observed of exact_source_disposition
  
  type exact_execution_binding = Keeper_event_queue_persistence.exact_execution_binding =
    { lease_id : string
    ; lease_sequence : int64
    ; slot_id : string
    ; call_id : string
    ; plan_fingerprint : string
    ; request_body_sha256 : string
    ; status : exact_execution_lease_status
    }

  type exact_write_outcome = Keeper_event_queue_persistence.exact_write_outcome =
    | Fsync_completed
    | Visible_sync_unconfirmed of string
  
  let bind_exact_execution_result
        ~base_path
        name
        ~lease
        ~slot_id
        ~call_id
        ~plan_fingerprint
        ~request_body_sha256
    =
    Keeper_event_queue_persistence.bind_exact_execution_result
      ~base_path
      ~keeper_name:name
      ~lease
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
      ()
  ;;
  
  (* TEL-OK: this facade only forwards the durable transition; the persistence
     SSOT owns its transition telemetry. *)
  let release_exact_execution_before_dispatch_result
        ~base_path
        name
        ~lease
        ~slot_id
        ~call_id
        ~plan_fingerprint
        ~request_body_sha256
    =
    Keeper_event_queue_persistence.release_exact_execution_before_dispatch_result
      ~base_path
      ~keeper_name:name
      ~lease
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
      ()
  ;;
  
  let quarantine_exact_execution_result
        ~base_path
        name
        ~lease
        ~terminal
        ~plan_fingerprint
        ~request_body_sha256
    =
    Keeper_event_queue_persistence.quarantine_exact_execution_result
      ~base_path
      ~keeper_name:name
      ~lease
      ~terminal
      ~plan_fingerprint
      ~request_body_sha256
      ()
  ;;

  let prepare_exact_source_disposition_result
        ~base_path
        name
        ~lease
        ~binding
        ~source
        ~outcome
        ~action
        ~prepared_at
    =
    Keeper_event_queue_persistence.prepare_exact_source_disposition_result
      ~base_path
      ~keeper_name:name
      ~lease
      ~binding
      ~source
      ~outcome
      ~action
      ~prepared_at
      ()
  ;;

  let finalize_exact_source_disposition_result
        ~base_path
        name
        ~settled_at
        ~lease
        ~disposition_id
    =
    Keeper_event_queue_persistence.finalize_exact_source_disposition_result
      ~base_path
      ~keeper_name:name
      ~settled_at
      ~lease
      ~disposition_id
      ~after_commit:(Publish.publish_pending ~base_path name)
      ()
  ;;
  
  let active_lease_result ~base_path name =
    match Keeper_registry.get ~base_path name with
    | None -> Error (Printf.sprintf "keeper not registered: %s" name)
    | Some _ ->
      Keeper_event_queue_persistence.active_lease_result
        ~base_path
        ~keeper_name:name
  ;;
  
  let transition_outbox_result ~base_path name =
    Keeper_event_queue_persistence.transition_outbox_result
      ~base_path
      ~keeper_name:name
  ;;
  
  let exact_execution_binding_result ~base_path name =
    Keeper_event_queue_persistence.exact_execution_binding_result
      ~base_path
      ~keeper_name:name
  ;;
  
  let mark_transition_projected_result ~base_path name ~transition_id =
    Keeper_event_queue_persistence.mark_transition_projected_result
      ~base_path
      ~keeper_name:name
      ~transition_id
  ;;
  
  let settle_exact_execution_result
        ~base_path
        name
        ~settled_at
        ~lease
        ~binding
        ~settlement
    =
    Keeper_event_queue_persistence.settle_exact_execution_result
      ~base_path
      ~keeper_name:name
      ~settled_at
      ~lease
      ~slot_id:binding.slot_id
      ~call_id:binding.call_id
      ~plan_fingerprint:binding.plan_fingerprint
      ~request_body_sha256:binding.request_body_sha256
      ~settlement
      ~after_commit:(Publish.publish_pending ~base_path name)
      ()
  ;;
end
