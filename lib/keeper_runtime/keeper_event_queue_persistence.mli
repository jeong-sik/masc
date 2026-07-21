(** Durable per-Keeper Event Layer state.

    [event-queue.json] keeps the v3 envelope containing pending stimuli, active
    typed leases, the monotonic lease sequence and the transition outbox.
    Older schemas are unsupported. [event-queue-inflight.json] is rejected
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
  | Approval_grant_unconsumed
  | Approval_grant_state_unavailable

type escalation_reason = Keeper_event_queue_state.escalation_reason =
  | Failure_judgment_requested
  | Failure_judgment_boundary_failed of { detail : string }
  | Failure_judgment_external_input_requested of
      { judge_runtime_id : string
      ; rationale : string
      }

type no_compaction_reason = Keeper_event_queue_state.no_compaction_reason =
  | No_eligible_history
  | Invalid_structural_source
  | Structurally_unchanged
  | Checkpoint_not_reduced

type no_compaction = Keeper_event_queue_state.no_compaction =
  { source : Keeper_checkpoint_ref.t
  ; reason : no_compaction_reason
  }

type accepted_cancellation = Keeper_event_queue_state.accepted_cancellation =
  { source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; owner_generation : int
  ; operator_operation_id : string
  ; reason : string
  }

type accepted_transfer = Keeper_event_queue_state.accepted_transfer =
  { source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; owner_generation : int
  ; operator_operation_id : string
  ; from_keeper : string
  ; to_keeper : string
  }

type settlement = Keeper_event_queue_state.settlement =
  | Ack
  | No_compaction of no_compaction
  | Cancel_accepted of accepted_cancellation
  | Transfer_accepted of accepted_transfer
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

val lease_stimuli : lease -> Keeper_event_queue.stimulus list
val lease_kind : lease -> lease_kind

val active_lease_result :
  base_path:string -> keeper_name:string -> (lease option, string) result

val transition_outbox_result :
  base_path:string -> keeper_name:string -> (outbox_entry list, string) result
(** Read the single pending projection entry for this Keeper lane.  The state
    machine blocks new claims until this list is drained. *)

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
(** Strict state read used by tests and operator projection. A malformed v3
    envelope or v3-plus-legacy residue is an [Error], never an empty queue.
    Committed WAL rows are replayed idempotently, checkpointed, and then
    compacted to the exact empty suffix before the state is returned. *)

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

val cancel_accepted_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  current_owner_generation:int ->
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
  current_owner_generation:int ->
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
  current_owner_generation:int ->
  settled_at:float ->
  transfer:accepted_transfer ->
  unit ->
  (settle_result, string) result
(** Append and fsync the canonical source-bearing transfer settlement before
    checkpointing removal of the exact pending source. *)

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

val enqueue_exact_stimulus_if_absent_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  Keeper_event_queue.stimulus ->
  (enqueue_stimulus_result, string) result
(** Transfer-only strict variant: an existing identity is idempotent only when
    the full source snapshot, including [arrived_at], is structurally equal.
    A changed snapshot or duplicate accounted identity is a conflict. *)

val persist_snapshot :
  base_path:string -> keeper_name:string -> (unit -> Keeper_event_queue.t) -> unit

val record_inflight :
  base_path:string -> keeper_name:string -> Keeper_event_queue.stimulus list -> unit
(** Legacy source/test adapter.  Writes a typed [Legacy_inflight] lease into the
    v3 envelope; it never creates [event-queue-inflight.json]. *)

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

val fleet_summary_json : now:float -> base_path:string -> Yojson.Safe.t
