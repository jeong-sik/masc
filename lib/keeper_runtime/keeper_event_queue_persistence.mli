(** Durable per-Keeper Event Layer state.

    [event-queue.json] keeps the v5 envelope containing pending stimuli, active
    typed leases, exact-execution dispatch fences, the monotonic lease
    sequence, transition outbox, and durable accepted-transfer target
    accounting. Only the current schema is accepted; stale or unknown state
    fails closed and requires reset. [event-queue-inflight.json] is rejected
    explicitly rather than migrated or treated as a second authority. *)

type lease_kind = Keeper_event_queue_state.lease_kind =
  | Single
  | Board_batch
  | Legacy_inflight

type requeue_reason = Keeper_event_queue_state.requeue_reason =
  | Cycle_busy
  | Turn_not_scheduled
  | Rotate_now
  | Cancelled
  | Cycle_crashed
  | Registration_recovery
  | Retry_after_observed
  | Context_compaction_retry
  | Transcript_quarantine_retry
  | Approval_grant_unconsumed
  | Approval_grant_state_unavailable

type exact_execution_terminal_cause = Keeper_event_queue_state.exact_execution_terminal_cause =
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

type exact_execution_terminal = Keeper_event_queue_state.exact_execution_terminal =
  { cause : exact_execution_terminal_cause
  ; slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  }

type exact_source_action = Keeper_event_queue_state.exact_source_action =
  | Consume_source

type exact_settlement_semantic = Keeper_event_queue_state.exact_settlement_semantic =
  | Exact_no_compaction
  | Exact_escalate

type exact_source_outcome = Keeper_event_queue_state.exact_source_outcome =
  | Terminal of exact_execution_terminal_cause

type exact_source_disposition = Keeper_event_queue_state.exact_source_disposition =
  { disposition_id : string
  ; source : Keeper_checkpoint_ref.t
  ; slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  ; outcome : exact_source_outcome
  ; action : exact_source_action
  ; semantic : exact_settlement_semantic
  ; prepared_at : float
  }

type exact_execution_lease_status = Keeper_event_queue_state.exact_execution_lease_status =
  | Dispatch_uncertain
  | Terminal_quarantined of exact_execution_terminal_cause
  | Disposition_prepared of exact_source_disposition

type exact_execution_binding = Keeper_event_queue_state.exact_execution_binding =
  { lease_id : string
  ; lease_sequence : int64
  ; slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  ; status : exact_execution_lease_status
  }

type exact_write_outcome =
  | Fsync_completed
  | Visible_sync_unconfirmed of string
(** [Fsync_completed] means the payload and parent-directory [Unix.fsync]
    calls both returned successfully. It is the process-restart dispatch
    fence, not a hardware/power-loss persistence or Darwin [F_FULLFSYNC]
    guarantee. [Visible_sync_unconfirmed _] means rename is visible but the
    parent sync did not complete. *)

type escalation_reason = Keeper_event_queue_state.escalation_reason =
  | Failure_judgment_requested
  | Failure_judgment_boundary_failed of { detail : string }
  | Failure_judgment_external_input_requested of
      { judge_runtime_id : string
      ; rationale : string
      }
  | Compaction_exact_lane_unconfigured of { source : Keeper_checkpoint_ref.t }
  | Compaction_exact_output_terminal of
      { source : Keeper_checkpoint_ref.t
      ; terminal : exact_execution_terminal
      }
  | Compaction_retry_exhausted of
      { attempts : int
      ; detail : string
      }
  | Compaction_floor_exceeded of
      { attempts : int
      ; detail : string
      }
  | Transcript_quarantine_retry_exhausted of
      { attempts : int
      ; detail : string
      }

type no_compaction_reason = Keeper_event_queue_state.no_compaction_reason =
  | No_eligible_history
  | Invalid_structural_source
  | Structurally_unchanged
  | Checkpoint_not_reduced
  | Exact_lane_unconfigured
  | Exact_execution_terminal of exact_execution_terminal

type no_compaction = Keeper_event_queue_state.no_compaction =
  { source : Keeper_checkpoint_ref.t
  ; reason : no_compaction_reason
  }

type accepted_cancellation = Keeper_event_queue_state.accepted_cancellation =
  { source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; owner_nonce : int
  ; operator_operation_id : string
  ; reason : string
  }

type accepted_transfer = Keeper_event_queue_state.accepted_transfer =
  { source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; owner_nonce : int
  ; operator_operation_id : string
  ; from_keeper : string
  ; to_keeper : string
  }

type source_terminal_receipt = Keeper_event_queue_state.source_terminal_receipt =
  | Fusion_terminal of Keeper_event_queue.fusion_completion
  | Background_job_terminal of Keeper_event_queue.bg_job_completion
  | Hitl_terminal of Keeper_event_queue.hitl_resolution

type accepted_source_terminal = Keeper_event_queue_state.accepted_source_terminal =
  { source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; owner_nonce : int
  ; operator_operation_id : string
  ; source_receipt : source_terminal_receipt
  }

type settlement = Keeper_event_queue_state.settlement =
  | Ack
  | No_compaction of no_compaction
  | Cancel_accepted of accepted_cancellation
  | Transfer_accepted of accepted_transfer
  | Settle_from_source_terminal of accepted_source_terminal
  | Settle_exact of exact_source_disposition
  | Requeue of requeue_reason
  | Escalate of
      { reason : escalation_reason
      ; successor : Keeper_event_queue.stimulus option
      }

type lease = Keeper_event_queue_state.lease
type transition_receipt = Keeper_event_queue_state.transition_receipt
type outbox_entry = Keeper_event_queue_state.outbox_entry

type settle_result =
  | Settled of transition_receipt
  | Already_settled of transition_receipt
  | Committed_followup_failed of
      { receipt : transition_receipt
      ; stage : [ `Checkpoint | `Wal_compaction | `Projection ]
      ; detail : string
      }

type transfer_projection_result =
  | Transfer_projected
  | Transfer_already_projected

val lease_stimuli : lease -> Keeper_event_queue.stimulus list
val lease_kind : lease -> lease_kind

val active_lease_result :
  base_path:string -> keeper_name:string -> (lease option, string) result

val transition_outbox_result :
  base_path:string -> keeper_name:string -> (outbox_entry list, string) result
(** Read the single pending projection entry for this Keeper lane.  The state
    machine blocks new claims until this list is drained. *)

val exact_execution_binding_result :
  base_path:string -> keeper_name:string -> (exact_execution_binding option, string) result

val load : base_path:string -> keeper_name:string -> Keeper_event_queue.t
(** Compatibility replay projection: pending followed by active lease stimuli.
    New live registry code should use {!load_pending} after explicitly
    recovering abandoned leases at registration. Raises [Failure] when the
    durable state is unavailable; it never substitutes an empty queue. *)

val load_result :
  base_path:string -> keeper_name:string -> (Keeper_event_queue.t, string) result
(** Result-returning replay projection for callers that can propagate a durable
    read failure. *)

val load_pending : base_path:string -> keeper_name:string -> Keeper_event_queue.t
(** Compatibility pending projection. Raises [Failure] on a durable read
    failure; use {!load_pending_result} in production control flow. *)

val load_pending_result :
  base_path:string -> keeper_name:string -> (Keeper_event_queue.t, string) result

type snapshot_pair =
  { pending : Keeper_event_queue.t
  ; inflight : Keeper_event_queue.t
  }

type snapshot_read_error_kind =
  | Invalid_path
  | Read_failed
  | Parse_failed

type snapshot_read_error =
  { kind : snapshot_read_error_kind
  ; path : string option
  ; message : string
  }

type snapshot_pair_with_errors =
  { pending : Keeper_event_queue.t
  ; inflight : Keeper_event_queue.t
  ; read_errors : snapshot_read_error list
  }

type snapshot_discovery =
  { keeper_names : string list
  ; read_error : string option
  }

val snapshot_read_error_kind_to_string : snapshot_read_error_kind -> string
val discover_keeper_names_with_snapshots : base_path:string -> snapshot_discovery
val load_snapshot_pair : base_path:string -> keeper_name:string -> snapshot_pair
val load_snapshot_pair_with_errors :
  base_path:string -> keeper_name:string -> snapshot_pair_with_errors

val load_state_result :
  base_path:string -> keeper_name:string -> (Keeper_event_queue_state.t, string) result
(** Strict state read used by tests and operator projection. A malformed
    current envelope or stale/unknown schema is an [Error], never an empty
    queue. Committed current-schema WAL rows are replayed idempotently,
    checkpointed, and then compacted to the exact empty suffix before the state
    is returned. *)

val claim_when_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  claimed_at:float ->
  ready:(Keeper_event_queue.stimulus -> bool) ->
  unit ->
  (lease option, string) result

val claim_board_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  claimed_at:float ->
  unit ->
  (lease option, string) result

val settle_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  settled_at:float ->
  lease:lease ->
  settlement:settlement ->
  unit ->
  (settle_result, string) result
(** Append and fsync the owner-bound canonical receipt before checkpointing the
    state snapshot. Once checkpointed, the exact WAL prefix is durably compacted
    rather than retained by an arbitrary size policy. A post-commit checkpoint,
    WAL-compaction or pending-projection failure is returned as a committed
    outcome, never relabelled as an uncommitted error. *)

val bind_exact_execution_result :
  base_path:string ->
  keeper_name:string ->
  lease:lease ->
  slot_id:string ->
  call_id:string ->
  plan_fingerprint:string ->
  request_body_sha256:string ->
  unit ->
  (exact_write_outcome, string) result
(** Bind the affine call identity before dispatch. Only [Ok Fsync_completed]
    permits the provider call to start. [Ok (Visible_sync_unconfirmed _)]
    means the replacement is visible but its parent-directory sync is
    unconfirmed; the
    exact identity must be settled terminally without POST or failover. An
    [Error] means the replacement was not visible. *)

val release_exact_execution_before_dispatch_result :
  base_path:string ->
  keeper_name:string ->
  lease:lease ->
  slot_id:string ->
  call_id:string ->
  plan_fingerprint:string ->
  request_body_sha256:string ->
  unit ->
  (exact_write_outcome, string) result
(** Remove a bound identity only while it is still pre-dispatch.
    [Fsync_completed] permits fallback to another slot.
    [Visible_sync_unconfirmed _] means the removal is visible but its
    directory sync is unconfirmed; the caller
    must return a source-bound terminal for the original identity and must not
    fail over. [Error] means the removal was not visible. *)

val quarantine_exact_execution_result :
  base_path:string ->
  keeper_name:string ->
  lease:lease ->
  terminal:exact_execution_terminal ->
  unit ->
  (exact_write_outcome, string) result
(** Persist the canonical post-dispatch terminal cause. A visible replacement
    with unconfirmed directory sync keeps that original cause and remains
    eligible for matching source-bound settlement. *)

val prepare_exact_source_disposition_result :
  base_path:string ->
  keeper_name:string ->
  lease:lease ->
  source:Keeper_checkpoint_ref.t ->
  terminal:exact_execution_terminal ->
  semantic:exact_settlement_semantic ->
  prepared_at:float ->
  unit ->
  (exact_source_disposition * exact_write_outcome, string) result

val finalize_exact_source_disposition_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  settled_at:float ->
  lease:lease ->
  disposition_id:string ->
  unit ->
  (settle_result, string) result

val settle_bound_exact_nonterminal_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  settled_at:float ->
  lease:lease ->
  slot_id:string ->
  call_id:string ->
  plan_fingerprint:string ->
  request_body_sha256:string ->
  settlement:settlement ->
  unit ->
  (settle_result, string) result
(** Commit only the identity-bound nonterminal Ack/retry/floor/failure-judgment
    cases. Exact terminal outcomes require durable source preparation and
    [finalize_exact_source_disposition_result]. *)

val cancel_accepted_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  current_owner_nonce:int ->
  settled_at:float ->
  lease:lease ->
  cancellation:accepted_cancellation ->
  unit ->
  (settle_result, string) result
(** Commit one terminal accepted cancellation under the same durable owner lock
    that reads the current queue revision. The pure state boundary checks the
    supplied owner generation and observed source revision before the receipt
    WAL is appended, so callers cannot split fence validation from commit. *)

val cancel_pending_accepted_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  current_owner_nonce:int ->
  settled_at:float ->
  cancellation:accepted_cancellation ->
  unit ->
  (settle_result, string) result
(** Append and fsync the canonical source-bearing cancellation receipt before
    checkpointing removal of the exact pending source. WAL replay can complete
    the transition from the pre-removal state after a crash. *)

val transfer_pending_accepted_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  current_owner_nonce:int ->
  settled_at:float ->
  transfer:accepted_transfer ->
  unit ->
  (settle_result, string) result
(** Append and fsync the canonical source-bearing transfer settlement before
    checkpointing removal of the exact pending source. *)

val settle_pending_from_source_terminal_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  current_owner_nonce:int ->
  settled_at:float ->
  source_terminal:accepted_source_terminal ->
  unit ->
  (settle_result, string) result

val prepare_registration_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  settled_at:float ->
  unit ->
  (Keeper_event_queue.t, string) result
(** Registration boundary for a newly-owned lane. Requeues an abandoned lease,
    records its stable [Registration_recovery] transition, and returns the
    resulting pending projection from the same durable transaction. A malformed
    state is an [Error]; registration must not substitute an empty queue.
    Post-commit [Error] names that fact; retry replays the exact WAL cursor. *)

val prepare_registration_after_exact_recovery_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  settled_at:float ->
  unit ->
  (Keeper_event_queue.t, string) result
(** Under one owner durable lock, replay the settlement WAL, finalize a
    validated terminal v5 exact disposition, then and only then apply ordinary
    registration recovery. Dispatch-uncertain bindings and source-less terminal
    quarantines remain fail-closed. *)

val mark_transition_projected_result :
  base_path:string ->
  keeper_name:string ->
  transition_id:string ->
  (unit, string) result

val persist :
  base_path:string -> keeper_name:string -> Keeper_event_queue.t -> unit

val update :
  base_path:string -> keeper_name:string -> (Keeper_event_queue.t -> Keeper_event_queue.t) -> unit

val update_result :
  ?after_commit:(unit -> unit) ->
  base_path:string ->
  keeper_name:string ->
  (Keeper_event_queue.t -> Keeper_event_queue.t) ->
  (unit, string) result

val update_checked_result :
  ?after_commit:(unit -> unit) ->
  base_path:string ->
  keeper_name:string ->
  (Keeper_event_queue.t -> (Keeper_event_queue.t, string) result) ->
  (unit, string) result

type enqueue_stimulus_result =
  | Enqueued
  | Already_present

val enqueue_stimulus_if_absent_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  Keeper_event_queue.stimulus ->
  (enqueue_stimulus_result, string) result
(** Atomically enqueue only when the same typed stimulus is absent from the
    full durable state: pending, active leases, and transition outbox. *)

val project_accepted_transfer_result :
  after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  transfer:accepted_transfer ->
  (transfer_projection_result, string) result
(** Atomically persist target-side transfer accounting with the exact enqueue.
    The accounting survives target consumption and makes later receipt replay
    return [Transfer_already_projected] without a second target effect. *)

val persist_snapshot :
  base_path:string -> keeper_name:string -> (unit -> Keeper_event_queue.t) -> unit

val record_inflight :
  base_path:string -> keeper_name:string -> Keeper_event_queue.stimulus list -> unit
(** Legacy source/test adapter. Writes a typed [Legacy_inflight] lease into the
    v5 envelope; it never creates [event-queue-inflight.json]. *)

val ack_inflight :
  base_path:string -> keeper_name:string -> Keeper_event_queue.stimulus list -> unit

val ack_consumed :
  base_path:string ->
  keeper_name:string ->
  Keeper_event_queue.stimulus list ->
  (unit, string) result

val drop_by_post_id :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  post_id:string ->
  unit ->
  (Keeper_event_queue.stimulus list, string) result

type owner_lifecycle =
  | Runnable
  | Paused_retained
  | Lifecycle_unknown of string

(** Fleet projection split by the caller's canonical durable owner-lifecycle
    read.  Queue persistence deliberately does not infer pause state from
    registry presence, event contents, or elapsed time. *)
val fleet_summary_json :
  now:float ->
  base_path:string ->
  owner_lifecycle:(keeper_name:string -> owner_lifecycle) ->
  Yojson.Safe.t
