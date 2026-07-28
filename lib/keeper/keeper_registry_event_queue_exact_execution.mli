module Make (Publish : sig
    val publish_pending : base_path:string -> string -> Keeper_event_queue.t -> unit
  end) : sig
  type exact_execution_terminal_cause =
    Keeper_event_queue_persistence.exact_execution_terminal_cause =
    | Exact_execution_failed
    | Exact_execution_cancelled
    | Domain_invalid_output
  | Compaction_produced_no_reduction
  | Compaction_increased_checkpoint
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
    ; plan_fingerprint : string
    ; request_body_sha256 : string
    }

  type exact_source_action = Keeper_event_queue_persistence.exact_source_action =
    | Consume_source

  type exact_settlement_semantic =
    Keeper_event_queue_persistence.exact_settlement_semantic =
    | Exact_no_compaction
    | Exact_escalate

  type exact_source_outcome = Keeper_event_queue_persistence.exact_source_outcome =
    | Terminal of exact_execution_terminal_cause

  type exact_source_disposition = Keeper_event_queue_persistence.exact_source_disposition

  type exact_execution_lease_status =
    Keeper_event_queue_persistence.exact_execution_lease_status =
    | Dispatch_uncertain
    | Terminal_quarantined of exact_execution_terminal_cause
    | Disposition_prepared of exact_source_disposition

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
  (* The lease-taking exact-execution fence (bind / release_before_dispatch /
     quarantine / prepare / finalize / settle_bound_exact_nonterminal) and
     active_lease_result lived here. #25969 moved production to peek/ack, after
     which no caller could obtain a lease and none of these was reachable. *)


  val exact_execution_binding_result :
    base_path:string -> string -> (exact_execution_binding option, string) result

end
