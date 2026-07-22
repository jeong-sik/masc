(** Pure durable state machine for one Keeper event queue owner.

    [event-queue.json] is the sole authority for pending stimuli, active
    leases, monotonic lease identity, and settlement projection work.  This
    module performs no I/O; persistence supplies the atomic file boundary and
    publishes [pending] into the live registry only after a durable commit. *)

type lease_kind =
  | Single
  | Board_batch
  | Legacy_inflight

type requeue_reason =
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

type escalation_reason =
  | Failure_judgment_requested
  | Failure_judgment_boundary_failed of { detail : string }
  | Failure_judgment_external_input_requested of
      { judge_runtime_id : string
      ; rationale : string
      }
  | Compaction_exact_lane_unconfigured of
      { source : Keeper_checkpoint_ref.t
      }
      (** The exact-output compaction lane is absent. The durable checkpoint
          source is retained and the event escalates without a retry successor. *)
  | Compaction_execution_may_have_dispatched
      (** Exact-output dispatch may have crossed the external-effect boundary.
          The source is escalated immediately without any retry successor. *)
  | Compaction_domain_invalid_output
      (** A dispatched exact-output response violated the MASC-owned domain
          contract. The source is escalated immediately without failover or
          retry. *)
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

type no_compaction_reason =
  | No_eligible_history
  | Invalid_structural_source
  | Structurally_unchanged
  | Checkpoint_not_reduced
  | Exact_lane_unconfigured
      (** The configured runtime has no exact-output lane for compaction. This
          is an operator-actionable precondition failure tied to the durable
          checkpoint source, not a stochastic provider failure. *)
  | Execution_may_have_dispatched
      (** Exact-output execution crossed the safe pre-dispatch boundary. The
          provider may already have received the request, so automatic retry
          could duplicate an outward effect. *)
  | Domain_invalid_output
      (** The provider returned JSON after dispatch, but it violated the
          MASC-owned compaction domain contract. A different slot must not be
          tried automatically for the same source. *)

type no_compaction =
  { source : Keeper_checkpoint_ref.t
  ; reason : no_compaction_reason
  }

type accepted_cancellation =
  { source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; owner_generation : int
  ; operator_operation_id : string
  ; reason : string
  }
(** Exact operator authority for terminally cancelling one accepted event.
    [source_revision] and [owner_generation] fence the observed paused owner;
    [operator_operation_id] makes replay/conflict explicit. *)

type accepted_transfer =
  { source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; owner_generation : int
  ; operator_operation_id : string
  ; from_keeper : string
  ; to_keeper : string
  }
(** Exact causal authority for terminally transferring one accepted event.
    The durable disposition receipt retains the target continuation binding;
    this settlement links the source queue terminal effect to that receipt by
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
  ; owner_generation : int
  ; operator_operation_id : string
  ; source_receipt : source_terminal_receipt
  }

val no_compaction_reason_label : no_compaction_reason -> string
val no_compaction_reason_of_label : string -> (no_compaction_reason, string) result

val escalation_reason_requests_external_input : escalation_reason -> bool
(** [true] only when the LLM judgment explicitly reports that the Keeper must
    await unavailable external input. A judgment-boundary failure remains a
    separate observed error. *)

type settlement =
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

type lease =
  { lease_id : string
  ; sequence : int64
  ; kind : lease_kind
  ; claimed_at : float option
  ; stimuli : Keeper_event_queue.stimulus list
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
val next_lease_sequence : t -> int64
val pending : t -> Keeper_event_queue.t
val leases : t -> lease list
val last_settlement : t -> transition_receipt option
val transition_outbox : t -> outbox_entry list
val accepted_transfer_projections : t -> accepted_transfer list
val lease_kind : lease -> lease_kind

val with_pending : Keeper_event_queue.t -> t -> t
val with_revision : int64 -> t -> t

val claim_when :
  claimed_at:float ->
  ready:(Keeper_event_queue.stimulus -> bool) ->
  t ->
  (t * lease option, string) result
(** Lease the earliest pending stimulus accepted by [ready]. Earlier unready
    stimuli retain their exact relative position, so one unavailable input
    cannot block unrelated ready work in the same Keeper lane. A successful
    claim advances the monotonic lease sequence in the same state. *)

val claim_board : claimed_at:float -> t -> (t * lease option, string) result
(** Lease every pending board stimulus as one ordered digest. *)

val add_legacy_inflight :
  Keeper_event_queue.stimulus list -> t -> (t * lease option, string) result
(** Migration/test compatibility boundary.  Adds one lease for legacy
    [event-queue-inflight.json] rows and removes matching pending identities. *)

val settle :
  settled_at:float ->
  lease:lease ->
  settlement:settlement ->
  t ->
  (t * settle_result, string) result
(** Atomically project one lease disposition into pure state.  Repeating the
    same semantic settlement returns [Already_settled]; a different settlement
    for an already-settled lease is an explicit conflict.

    [Retry_after_observed] and [Context_compaction_retry] retain the exact
    leased stimuli at the pending FIFO tail so unrelated work in the same lane
    can proceed before another provider attempt. [No_compaction] is accepted
    only for a lease containing exactly one typed
    [Manual_compaction_requested] stimulus; it cannot retire product work whose
    provider turn failed. Non-finite settlement times are rejected. *)

val cancel_accepted :
  current_owner_generation:int ->
  settled_at:float ->
  lease:lease ->
  cancellation:accepted_cancellation ->
  t ->
  (t * settle_result, string) result
(** Terminally settle exactly one leased accepted event when both the durable
    queue revision and owner generation still match the operator snapshot.
    Generic {!settle} rejects [Cancel_accepted], so callers cannot bypass this
    owner-fenced boundary. Replaying the same committed cancellation is
    idempotent; a different operation is a conflict. *)

val cancel_pending_accepted :
  current_owner_generation:int ->
  settled_at:float ->
  cancellation:accepted_cancellation ->
  t ->
  (t * settle_result, string) result
(** Atomically create and terminally settle a synthetic single-event lease for
    the exact pending [cancellation.source]. The source revision and owner
    generation are checked before removal. This pure transition is committed
    through a source-bearing WAL outbox entry by persistence. *)

val transfer_pending_accepted :
  current_owner_generation:int ->
  settled_at:float ->
  transfer:accepted_transfer ->
  t ->
  (t * settle_result, string) result
(** Atomically create and terminally settle a synthetic single-event lease for
    the exact pending transfer source. The source revision and owner generation
    are checked before removal, and the source-bearing WAL remains the replay
    authority until the target projection completes. *)

val settle_pending_from_source_terminal :
  current_owner_generation:int ->
  settled_at:float ->
  source_terminal:accepted_source_terminal ->
  t ->
  (t * settle_result, string) result
(** Terminally settle one exact pending event only when its closed payload
    exactly matches [source_terminal.source_receipt]. *)

val accepted_cancellation_replay :
  lease ->
  accepted_cancellation ->
  t ->
  (transition_receipt option, string) result
(** Return the canonical receipt for an already committed exact cancellation
    without applying current owner-generation or queue-revision fences. A
    different terminal settlement for the same lease is an explicit conflict. *)

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

val accepted_pending_source_terminal_replay :
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

val recover_leases : settled_at:float -> t -> (t, string) result
(** Requeue every active lease with [Registration_recovery], preserving claim
    and stimulus order and emitting stable transition receipts. *)

val active_lease : t -> lease option
(** Oldest unsettled lease, if any.  A restarted lane resumes this lease before
    claiming new pending work. *)

val mark_transition_projected : transition_id:string -> t -> (t, string) result
(** Atomically retire a durable outbox entry after an external projector has
    materialized its stable [event_id], retaining only the last receipt for an
    immediate idempotent retry. Unknown transition ids fail closed. *)

val remove_by_post_id :
  Keeper_event_queue.post_id -> t -> Keeper_event_queue.stimulus list * t

val release_legacy_inflight :
  Keeper_event_queue.stimulus list -> t -> t
(** Compatibility-only projection for the retired split-file API.  Removes
    matching identities from active leases while leaving pending untouched.
    New runtime code must settle the opaque lease instead. *)

val lease_to_yojson : lease -> Yojson.Safe.t
val lease_of_yojson : Yojson.Safe.t -> (lease, string) result
val transition_receipt_equal : transition_receipt -> transition_receipt -> bool
val transition_receipt_to_yojson : transition_receipt -> Yojson.Safe.t
val transition_receipt_of_yojson : Yojson.Safe.t -> (transition_receipt, string) result
val outbox_entry_to_yojson : outbox_entry -> Yojson.Safe.t
val outbox_entry_of_yojson : Yojson.Safe.t -> (outbox_entry, string) result
val replay_transition_outbox_entry : outbox_entry -> t -> (t, string) result
(** Replay a source-bearing committed transition. Active-lease settlements use
    their exact lease; pending accepted cancellations reconstruct the same
    synthetic lease from the receipt sequence and exact source. *)
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result

val schema : string
(** ["keeper.event_queue.state.v4"]. Strict v3 snapshots are read as the sole
    supported predecessor and upgraded on their next durable mutation. *)
