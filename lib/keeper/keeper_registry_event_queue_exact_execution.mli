module Make (Publish : sig
    val publish_pending : base_path:string -> string -> Keeper_event_queue.t -> unit
  end) : sig
  type exact_execution_terminal_cause =
    Keeper_event_queue_persistence.exact_execution_terminal_cause =
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

  type exact_execution_lease_status =
    Keeper_event_queue_persistence.exact_execution_lease_status =
    | Dispatch_uncertain
    | Terminal_quarantined of exact_execution_terminal_cause

  type exact_execution_binding = Keeper_event_queue_persistence.exact_execution_binding =
    { lease_id : string
    ; lease_sequence : int64
    ; slot_id : string
    ; call_id : string
    ; plan_fingerprint : string
    ; request_body_sha256 : string
    ; status : exact_execution_lease_status
    }

  val bind_exact_execution_result :
    base_path:string ->
    string ->
    lease:Keeper_event_queue_persistence.lease ->
    slot_id:string ->
    call_id:string ->
    plan_fingerprint:string ->
    request_body_sha256:string ->
    (unit, string) result

  val release_exact_execution_before_dispatch_result :
    base_path:string ->
    string ->
    lease:Keeper_event_queue_persistence.lease ->
    slot_id:string ->
    call_id:string ->
    plan_fingerprint:string ->
    request_body_sha256:string ->
    (unit, string) result

  val quarantine_exact_execution_result :
    base_path:string ->
    string ->
    lease:Keeper_event_queue_persistence.lease ->
    terminal:exact_execution_terminal ->
    plan_fingerprint:string ->
    request_body_sha256:string ->
    (unit, string) result

  val active_lease_result :
    base_path:string ->
    string ->
    (Keeper_event_queue_persistence.lease option, string) result

  val transition_outbox_result :
    base_path:string ->
    string ->
    (Keeper_event_queue_persistence.outbox_entry list, string) result

  val exact_execution_binding_result :
    base_path:string -> string -> (exact_execution_binding option, string) result

  val mark_transition_projected_result :
    base_path:string -> string -> transition_id:string -> (unit, string) result

  val settle_exact_execution_result :
    base_path:string ->
    string ->
    settled_at:float ->
    lease:Keeper_event_queue_persistence.lease ->
    binding:exact_execution_binding ->
    settlement:Keeper_event_queue_persistence.settlement ->
    (Keeper_event_queue_persistence.settle_result, string) result
end
