(** Pure durable state machine for one Keeper event queue owner.

    [event-queue.json] is the sole authority for pending stimuli, active
    leases, monotonic lease identity, and settlement projection work.  This
    module performs no I/O; persistence supplies the atomic file boundary and
    publishes [pending] into the live registry only after a durable commit. *)

type lease_kind =
  | Single
  | Board_batch

type pending_selection =
  { source_revision : int64
  ; kind : lease_kind
  ; stimuli : Keeper_event_queue.stimulus list
  }

type requeue_reason =
  | Cycle_busy
  | Turn_not_scheduled
  | Rotate_now
  | Cancelled
  | Cycle_crashed
  | Registration_recovery
  | Retry_after_observed
  | Context_compaction_retry

type exact_execution_terminal_cause =
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

type exact_execution_terminal =
  { cause : exact_execution_terminal_cause
  ; slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  }
(** One OAS-owned affine call that crossed, or can no longer safely be assumed
    not to have crossed, the dispatch boundary. The complete producer proof is
    mandatory and survives the queue receipt/WAL codec. *)

type exact_source_action = Consume_source

type exact_settlement_semantic =
  | Exact_no_compaction
  | Exact_escalate

type exact_source_outcome = Terminal of exact_execution_terminal_cause

type exact_source_disposition =
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
(** Immutable terminal source disposition for one exact call. The ID is the
    SHA-256 of its stable proof, outcome, semantic, and action fields.
    [prepared_at] is observational and excluded from identity. *)

type exact_execution_lease_status =
  | Dispatch_uncertain
  | Terminal_quarantined of exact_execution_terminal_cause
      (** Current-schema terminal quarantine before a source disposition is
          prepared. It has no source authority and can never be finalized or
          registration-requeued. *)
  | Disposition_prepared of exact_source_disposition

type exact_execution_binding =
  { lease_id : string
  ; lease_sequence : int64
  ; slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  ; status : exact_execution_lease_status
  }
(** Durable pre-dispatch fence for one OAS exact-output attempt. A bound lease
    cannot pass through generic settlement or registration recovery. *)

type escalation_reason =
  | Compaction_exact_lane_unconfigured of
      { source : Keeper_checkpoint_ref.t
      }
      (** The exact-output compaction lane is absent. The durable checkpoint
          source is retained and the event escalates without a retry successor. *)
  | Compaction_exact_output_terminal of
      { source : Keeper_checkpoint_ref.t
      ; terminal : exact_execution_terminal
      }
      (** A source-bound exact-output call is terminal. The checkpoint source,
          slot, call ID, and categorical cause are durably retained; no retry
          successor is legal. *)
  | Compaction_retry_exhausted of
      { attempts : int
      ; detail : string
      }
      (** RFC-0351 S0 / #25461: settled instead of
          [Requeue Context_compaction_retry] once consecutive manual-compaction
          failures reach the escalation threshold.  A requeue is not an ack, so
          without this ceiling the same stimulus re-enters every heartbeat
          cycle. *)
  | Compaction_floor_exceeded of
      { attempts : int
      ; detail : string
      }
      (** RFC-0351 S0 / #25538: consecutive provider-overflow episodes reached
          the threshold even though compactions were committing — the
          committed savings cannot bring the context under the provider
          window (an incompressible floor).  Distinct from
          [Compaction_retry_exhausted] so "compaction keeps failing" and
          "compaction succeeds but cannot help" stay operator-distinguishable. *)
  | Transcript_corruption_requires_reset of { detail : string }
      (** Structural transcript corruption is terminal for automatic
          execution. The first failure pauses the Keeper and consumes the
          source lease without a successor until explicit operator reset. *)

type no_compaction_reason =
  | No_eligible_history
  | Invalid_structural_source
  | Structurally_unchanged
  | Checkpoint_not_reduced
  | Exact_lane_unconfigured
      (** The configured runtime has no exact-output lane for compaction. This
          is an operator-actionable precondition failure tied to the durable
          checkpoint source, not a stochastic provider failure. *)
  | Exact_execution_terminal of exact_execution_terminal
      (** Exact-output execution is affine and terminal. The typed cause plus
          OAS slot/call identity forbids a second attempt for this source. *)

type no_compaction =
  { source : Keeper_checkpoint_ref.t
  ; reason : no_compaction_reason
  }

type accepted_cancellation =
  { source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; owner_nonce : int
  ; operator_operation_id : string
  ; reason : string
  }
(** Exact operator authority for terminally cancelling one accepted event.
    [source_revision] and [owner_nonce] fence the observed paused owner;
    [operator_operation_id] makes replay/conflict explicit. *)

type accepted_transfer =
  { source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; owner_nonce : int
  ; operator_operation_id : string
  ; from_keeper : string
  ; to_keeper : string
  }
(** Exact causal authority for terminally transferring one accepted event.
    The durable disposition receipt retains the target continuation binding;
    this ACK links the source queue terminal effect to that receipt by
    stable operator operation ID. *)

type source_terminal_receipt =
  | Fusion_terminal of Keeper_event_queue.fusion_completion
  | Background_job_terminal of Keeper_event_queue.bg_job_completion
  | Hitl_terminal of Keeper_event_queue.hitl_resolution
(** Closed terminal source families that are intrinsically represented by a
    durable event payload. No prose or external status inference is admitted. *)

type accepted_source_terminal =
  { source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; owner_nonce : int
  ; operator_operation_id : string
  ; source_receipt : source_terminal_receipt
  }

type manual_compaction_auxiliary =
  | Compaction_commit_durability_unknown of { detail : string }
  | Compaction_commit_observer_failed of
      { detail : string
      ; backtrace_present : bool
      }
  | Compaction_release_process_lock_failed of { detail : string }
  | Compaction_post_commit_unwind_interrupted of
      { detail : string
      ; backtrace_present : bool
      }
  | Compaction_history_write_failed of
      { detail : string
      ; backtrace_present : bool
      }

type manual_compaction_lifecycle =
  | Compaction_completion_applied
  | Compaction_completion_rejected_failure_dispatched of
      { completion_error : string }
  | Compaction_completion_rejected_failure_dispatch_failed of
      { completion_error : string
      ; failure_dispatch_error : string
      }

type manual_compaction_commit =
  { installed_ref : Keeper_checkpoint_ref.t
  ; auxiliary : manual_compaction_auxiliary list
  ; lifecycle : manual_compaction_lifecycle
  ; manifest_error : string option
  }

type manual_compaction_followup =
  | Compaction_commit_ack

val manual_compaction_commit_requires_operator_action
  :  manual_compaction_commit
  -> bool

val no_compaction_reason_label : no_compaction_reason -> string
val no_compaction_reason_of_label : string -> (no_compaction_reason, string) result
val no_compaction_reason_to_string : no_compaction_reason -> string
val exact_execution_terminal_cause_label : exact_execution_terminal_cause -> string
val exact_execution_terminal_cause_of_label
  :  string
  -> (exact_execution_terminal_cause, string) result
val exact_execution_terminal_to_string : exact_execution_terminal -> string

type settlement =
  | Ack
  | Manual_compaction_committed of
      { commit : manual_compaction_commit
      ; followup : manual_compaction_followup
      }
  | No_compaction of no_compaction
  | Cancel_accepted of accepted_cancellation
  | Transfer_accepted of accepted_transfer
  | Ack_source_terminal of accepted_source_terminal
  | Settle_exact of exact_source_disposition
  | Requeue of requeue_reason
  | Escalate of
      { reason : escalation_reason
      ; successor : Keeper_event_queue.stimulus option
      }

type transition_receipt =
  { transition_id : string
  ; event_id : string
  ; lease_id : string
  ; lease_sequence : int64
  ; settled_at : float
  ; settlement : settlement
  }

type outbox_entry =
  { receipt : transition_receipt
  ; stimuli : Keeper_event_queue.stimulus list
  }

type t

type settle_result =
  | Settled of transition_receipt
  | Already_settled of transition_receipt

type transfer_projection_result =
  | Transfer_projected
  | Transfer_already_projected

val empty : t
val revision : t -> int64
val pending : t -> Keeper_event_queue.t
val last_settlement : t -> transition_receipt option
val transition_outbox : t -> outbox_entry list
val accepted_transfer_projections : t -> accepted_transfer list

val with_pending : Keeper_event_queue.t -> t -> t
val with_revision : int64 -> t -> t

val peek_when :
  ready:(Keeper_event_queue.stimulus -> bool) ->
  t ->
  pending_selection option

val validate_pending_selection :
  selection:pending_selection ->
  t ->
  (unit, string) result
(** Read-only exact immutable selection validation. Unrelated pending entries
    and queue revisions do not invalidate the selected source. *)

val ack_pending :
  selection:pending_selection ->
  t ->
  (t, string) result
(** Compare-and-remove the exact immutable selected stimulus snapshot.
    Unrelated queue revisions and enqueues are allowed; a missing, duplicated,
    or changed selected identity fails closed. *)

val exact_execution_binding : t -> exact_execution_binding option

val cancel_pending_accepted :
  current_owner_nonce:int ->
  settled_at:float ->
  cancellation:accepted_cancellation ->
  t ->
  (t * settle_result, string) result
(** Atomically create and terminally settle a synthetic single-event lease for
    the exact pending [cancellation.source]. The source revision and owner
    generation are checked before removal. This pure transition is committed
    through a source-bearing WAL outbox entry by persistence. *)

val transfer_pending_accepted :
  current_owner_nonce:int ->
  settled_at:float ->
  transfer:accepted_transfer ->
  t ->
  (t * settle_result, string) result
(** Atomically create and terminally settle a synthetic single-event lease for
    the exact pending transfer source. The source revision and owner generation
    are checked before removal, and the source-bearing WAL remains the replay
    authority until the target projection completes. *)

val ack_pending_source_terminal :
  current_owner_nonce:int ->
  settled_at:float ->
  source_terminal:accepted_source_terminal ->
  t ->
  (t * settle_result, string) result
(** ACK one exact pending event only when its closed payload
    exactly matches [source_terminal.source_receipt]. *)

val accepted_pending_cancellation_replay :
  accepted_cancellation ->
  t ->
  (transition_receipt option, string) result
(** Look up an already committed pending cancellation by its stable operator
    operation ID and exact source-bearing settlement. *)

val accepted_pending_transfer_replay :
  accepted_transfer ->
  t ->
  (transition_receipt option, string) result
(** Look up an already committed pending transfer by its stable operator
    operation ID and exact source-bearing settlement. *)

val project_accepted_transfer :
  accepted_transfer -> t -> (t * transfer_projection_result, string) result
(** Atomically account for one exact target-side transfer projection and
    enqueue its source only on the first projection. The durable accounting
    survives target consumption, so receipt replay cannot enqueue the same
    transferred event again. *)

val accepted_pending_source_terminal_ack_replay :
  accepted_source_terminal ->
  t ->
  (transition_receipt option, string) result

val source_terminal_receipt_of_stimulus :
  Keeper_event_queue.stimulus -> (source_terminal_receipt, string) result
(** Accept only [Fusion_completed], [Bg_completed], or [Hitl_resolved] and
    retain their exact typed terminal payload. *)

val replay_transition_receipt : transition_receipt -> t -> (t, string) result
(** Apply one canonical durable receipt to its exact active lease. Replaying
    the same retained receipt is idempotent; a different receipt or a missing
    lease is an explicit conflict. *)

val mark_transition_projected : transition_id:string -> t -> (t, string) result
(** Atomically retire a durable outbox entry after an external projector has
    materialized its stable [event_id], retaining only the last receipt for an
    immediate idempotent retry. Unknown transition ids fail closed. *)

val remove_by_post_id :
  Keeper_event_queue.post_id -> t -> Keeper_event_queue.stimulus list * t

val transition_receipt_equal : transition_receipt -> transition_receipt -> bool
val transition_receipt_to_yojson : transition_receipt -> Yojson.Safe.t
val transition_receipt_of_yojson : Yojson.Safe.t -> (transition_receipt, string) result
val outbox_entry_to_yojson : outbox_entry -> Yojson.Safe.t
val outbox_entry_of_yojson : Yojson.Safe.t -> (outbox_entry, string) result
val legacy_source_terminal_ack_outbox_entry_of_yojson :
  Yojson.Safe.t -> (outbox_entry, string) result
(** Recovery-only decoder for a v8 source-terminal outbox. It canonicalizes
    the removed internal settlement label to [Ack_source_terminal] while
    preserving the historical transition/event identity. New writes never use
    this path. *)
val replay_transition_outbox_entry : outbox_entry -> t -> (t, string) result
(** Replay a source-bearing committed transition. Active-lease settlements use
    their exact lease; pending accepted cancellations reconstruct the same
    synthetic lease from the receipt sequence and exact source. *)
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result

val schema : string
(** ["keeper.event_queue.state.v9"] is the current write schema. Historical
    v7/v8 snapshots are accepted only at the durable recovery boundary;
    unknown schemas fail closed and require a runtime reset. *)
