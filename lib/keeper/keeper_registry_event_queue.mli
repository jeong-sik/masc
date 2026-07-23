(** Per-keeper event-queue access.

    SSOT for enqueueing / draining the per-keeper stimulus queue.
    The MASC-owned v2 envelope is authoritative.  Mutations commit that one
    durable state first, then publish its pending projection into the
    entry-owned [event_queue : Keeper_event_queue.t Atomic.t].  No central
    registry Atomic is touched. *)

type lease = Keeper_event_queue_persistence.lease

type requeue_reason = Keeper_event_queue_persistence.requeue_reason =
  | Cycle_busy
  | Turn_not_scheduled
  | Rotate_now
  | Cancelled
  | Cycle_crashed
  | Registration_recovery
  | Retry_after_observed
  | Context_compaction_retry
  | Approval_grant_unconsumed
  | Approval_grant_state_unavailable

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

type exact_execution_lease_status = Keeper_event_queue_persistence.exact_execution_lease_status =
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

type escalation_reason = Keeper_event_queue_persistence.escalation_reason =
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

type no_compaction_reason = Keeper_event_queue_persistence.no_compaction_reason =
  | No_eligible_history
  | Invalid_structural_source
  | Structurally_unchanged
  | Checkpoint_not_reduced
  | Exact_lane_unconfigured
  | Exact_execution_terminal of exact_execution_terminal

type no_compaction = Keeper_event_queue_persistence.no_compaction =
  { source : Keeper_checkpoint_ref.t
  ; reason : no_compaction_reason
  }

type accepted_cancellation = Keeper_event_queue_persistence.accepted_cancellation =
  { source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; owner_generation : int
  ; operator_operation_id : string
  ; reason : string
  }

type accepted_transfer = Keeper_event_queue_persistence.accepted_transfer =
  { source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; owner_generation : int
  ; operator_operation_id : string
  ; from_keeper : string
  ; to_keeper : string
  }

type source_terminal_receipt = Keeper_event_queue_persistence.source_terminal_receipt =
  | Fusion_terminal of Keeper_event_queue.fusion_completion
  | Background_job_terminal of Keeper_event_queue.bg_job_completion
  | Hitl_terminal of Keeper_event_queue.hitl_resolution

type accepted_source_terminal = Keeper_event_queue_persistence.accepted_source_terminal =
  { source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; owner_generation : int
  ; operator_operation_id : string
  ; source_receipt : source_terminal_receipt
  }

type settlement = Keeper_event_queue_persistence.settlement =
  | Ack
  | No_compaction of no_compaction
  | Cancel_accepted of accepted_cancellation
  | Transfer_accepted of accepted_transfer
  | Settle_from_source_terminal of accepted_source_terminal
  | Requeue of requeue_reason
  | Escalate of
      { reason : escalation_reason
      ; successor : Keeper_event_queue.stimulus option
      }

type transition_receipt = Keeper_event_queue_persistence.transition_receipt
type outbox_entry = Keeper_event_queue_persistence.outbox_entry

type settle_result = Keeper_event_queue_persistence.settle_result =
  | Settled of transition_receipt
  | Already_settled of transition_receipt
  | Committed_followup_failed of
      { receipt : transition_receipt
      ; stage : [ `Checkpoint | `Wal_compaction | `Projection ]
      ; detail : string
      }

val lease_stimuli : lease -> Keeper_event_queue.stimulus list
val lease_kind : lease -> Keeper_event_queue_persistence.lease_kind

val active_lease_result :
  base_path:string -> string -> (lease option, string) result

val transition_outbox_result :
  base_path:string -> string -> (outbox_entry list, string) result

val exact_execution_binding_result :
  base_path:string -> string -> (exact_execution_binding option, string) result

val mark_transition_projected_result :
  base_path:string -> string -> transition_id:string -> (unit, string) result

val claim_when_result :
  base_path:string ->
  string ->
  claimed_at:float ->
  ready:(Keeper_event_queue.stimulus -> bool) ->
  (lease option, string) result

val claim_board_result :
  base_path:string -> string -> claimed_at:float -> (lease option, string) result

val settle_result :
  base_path:string ->
  string ->
  settled_at:float ->
  lease:lease ->
  settlement:settlement ->
  (settle_result, string) result

val settle_exact_execution_result :
  base_path:string ->
  string ->
  settled_at:float ->
  lease:lease ->
  binding:exact_execution_binding ->
  settlement:settlement ->
  (settle_result, string) result

val bind_exact_execution_result :
  base_path:string ->
  string ->
  lease:lease ->
  slot_id:string ->
  call_id:string ->
  plan_fingerprint:string ->
  request_body_sha256:string ->
  (unit, string) result

val release_exact_execution_before_dispatch_result :
  base_path:string ->
  string ->
  lease:lease ->
  slot_id:string ->
  call_id:string ->
  plan_fingerprint:string ->
  request_body_sha256:string ->
  (unit, string) result

val quarantine_exact_execution_result :
  base_path:string ->
  string ->
  lease:lease ->
  terminal:exact_execution_terminal ->
  plan_fingerprint:string ->
  request_body_sha256:string ->
  (unit, string) result

val cancel_accepted_result :
  base_path:string ->
  string ->
  current_owner_generation:int ->
  settled_at:float ->
  lease:lease ->
  cancellation:accepted_cancellation ->
  (settle_result, string) result
(** Commit an owner-fenced accepted cancellation and publish the resulting
    pending projection to the exact live registry lane after durable commit. *)

val cancel_pending_accepted_result :
  base_path:string ->
  string ->
  current_owner_generation:int ->
  settled_at:float ->
  cancellation:accepted_cancellation ->
  (settle_result, string) result
(** Commit an exact pending accepted cancellation and publish the post-commit
    pending projection when the owner currently has a live registry lane. *)

val transfer_pending_accepted_result :
  base_path:string ->
  string ->
  current_owner_generation:int ->
  settled_at:float ->
  transfer:accepted_transfer ->
  (settle_result, string) result
(** Commit an exact pending accepted transfer settlement and publish the
    post-commit source pending projection when the owner is registered. *)

val settle_pending_from_source_terminal_result :
  base_path:string ->
  string ->
  current_owner_generation:int ->
  settled_at:float ->
  source_terminal:accepted_source_terminal ->
  (settle_result, string) result

(** Enqueue a stimulus on the keeper's event queue. When the keeper is not
    registered yet, persist the stimulus to the durable snapshot so later
    registration can replay it instead of dropping the wake at the
    restart/register boundary. *)
val enqueue : base_path:string -> string -> Keeper_event_queue.stimulus -> unit

val enqueue_durable_result :
  base_path:string
  -> string
  -> Keeper_event_queue.stimulus
  -> (unit, string) result
(** Identity-deduplicated enqueue with an explicit durable-commit result.
    Unlike {!enqueue}, this first commits the pending snapshot and only then
    updates the live queue. Use it when the stimulus is the sole carrier of an
    external decision and the caller must not acknowledge delivery on a failed
    write. An existing identical [post_id] is idempotent; the same [post_id]
    with a different typed payload is an explicit conflict. *)

type enqueue_if_missing_durable_result =
  | Enqueued
  | Already_present
  | Identity_conflict of string
  | Storage_error of string

val enqueue_if_missing_durable_result :
  base_path:string
  -> event_id:string
  -> string
  -> Keeper_event_queue.stimulus
  -> enqueue_if_missing_durable_result
(** Durably enqueue a judged Board-attention event by its opaque producer
    identity. [event_id] must byte-equal the [candidate_id] carried by the
    typed [Board_attention] payload. No post id, content, or other derived
    field participates in identity. *)

type enqueue_stimulus_durable_result =
  | Stimulus_enqueued
  | Stimulus_already_present
  | Stimulus_storage_error of string

val enqueue_stimulus_durable_result :
  base_path:string
  -> string
  -> Keeper_event_queue.stimulus
  -> enqueue_stimulus_durable_result
(** Durably enqueue an already-typed deterministic stimulus only when its
    {!Keeper_event_queue.stimulus_identity_equal} identity is absent from
    pending, active leases, and the transition outbox. This explicit-result
    path is for structurally addressed signals whose delivery must commit
    before a wake hint. Board-attention judgments use the stricter
    opaque-event-id API above. *)

val project_accepted_transfer_durable_result :
  base_path:string
  -> string
  -> transfer:accepted_transfer
  -> enqueue_stimulus_durable_result
(** Strict target transfer projection. The exact source and operation identity
    are durably accounted in the target queue state before the pending
    projection becomes visible. Accounting survives consumption. *)

val enqueue_hitl_resolution_durable_result :
  base_path:string
  -> keeper_name:string
  -> approval_id:string
  -> decision:Keeper_event_queue.hitl_resolution_decision
  -> channel:Keeper_continuation_channel.t
  -> (unit, string) result
(** Build and durably enqueue the canonical [Hitl_resolved] stimulus. This is
    the single construction boundary shared by the server composition root and
    nonblocking-approval tests; callers may signal a live fiber only after this
    function returns [Ok ()]. *)

(** Read-only snapshot of the keeper's queue. If the keeper is not registered,
    read the durable snapshot so diagnostics still expose pending replay. *)
val snapshot : base_path:string -> string -> Keeper_event_queue.t

val drop_by_post_id :
  base_path:string
  -> string
  -> post_id:string
  -> (Keeper_event_queue.stimulus list, string) result
(** Remove matching stimuli from the live queue plus durable pending/in-flight
    snapshots, returning the exact stimuli that were dropped. Returns [Error _]
    when durable removal fails so callers do not clear recovery state while a
    replayable stimulus remains on disk. *)
