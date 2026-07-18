(** Durable per-Keeper Event Layer state.

    [event-queue-v4.json] and [event-queue-v4-settlements.jsonl] are the sole
    current authority. The retired [event-queue.json],
    [event-queue-settlements.jsonl], and [event-queue-inflight.json] epoch is
    never decoded, migrated, renamed, deleted, or used as fallback authority.
    Its raw presence is reported as operator-action residue while an absent v4
    authority is a valid empty lane. *)

type lease_kind = Keeper_event_queue_state.lease_kind =
  | Single
  | Board_batch

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

type settlement = Keeper_event_queue_state.settlement =
  | Ack
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
val lease_sequence : lease -> int64

val active_lease_result :
  base_path:string -> keeper_name:string -> (lease option, string) result

val transition_outbox_result :
  base_path:string -> keeper_name:string -> (outbox_entry list, string) result
(** Read the single pending projection entry for this Keeper lane.  The state
    machine blocks new claims until this list is drained. *)

val with_reaction_coordination_lock_result :
  base_path:string -> keeper_name:string -> (unit -> 'a) -> ('a, string) result
(** Serialize a compound operation that crosses the queue and its reaction
    authority for one Keeper lane.  The queue owns this separate durable lock;
    callers may safely enter ordinary queue transactions from [f] because this
    is not the queue state owner lock.  Scheduled terminal-check/enqueue and
    outbox projection/retirement share this boundary so a terminal settlement
    cannot be retired and then resurrected as pending. Board recovery admission
    and cursor ACK share it so the cursor never passes non-durable work. *)

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

type snapshot_read_error_kind =
  | Invalid_path
  | Read_failed
  | Parse_failed
  | Retired_epoch_residue

type snapshot_read_error =
  { kind : snapshot_read_error_kind
  ; path : string option
  ; message : string
  }

type snapshot_source_generation =
  { snapshot_present : bool
  ; snapshot_revision : int64
  ; observed_revision : int64
  ; settlement_wal_end_offset : int
  ; settlement_wal_row_count : int
  }
(** Immutable evidence identifying the exact durable queue generation that an
    observation projected. [snapshot_revision] is the revision encoded in the
    primary v4 snapshot (or the empty-state revision when no snapshot exists).
    [observed_revision] includes a committed settlement WAL replay performed
    only in memory. The WAL byte boundary and decoded-row count make that
    distinction explicit without creating another authority. *)

type snapshot_observation =
  { pending : Keeper_event_queue.t
  ; inflight : Keeper_event_queue.t
  ; transition_outbox_count : int
  ; source_generation : snapshot_source_generation option
  ; read_errors : snapshot_read_error list
  }
(** Read-only projection of one Keeper lane. [source_generation = None] iff
    the current v4 authority could not be observed. [read_errors] may coexist
    with [Some source_generation] when retired-epoch residue is present; that
    residue is operator evidence and never invalidates or augments current
    queue contents. *)

val snapshot_source_generation_to_yojson :
  snapshot_source_generation -> Yojson.Safe.t
(** Canonical dashboard/tool evidence encoding. Revisions are strings so the
    full int64 domain survives JavaScript transport. *)

type snapshot_discovery =
  { keeper_names : string list
  ; read_error : string option
  }

val snapshot_read_error_kind_to_string : snapshot_read_error_kind -> string
val snapshot_read_error_to_yojson : snapshot_read_error -> Yojson.Safe.t
(** Lossless dashboard encoding. Every error carries its typed kind, exact
    path when one exists, message, and [operator_action_required = true]. *)
val discover_keeper_names_with_snapshots : base_path:string -> snapshot_discovery
val observe_snapshot :
  base_path:string -> keeper_name:string -> snapshot_observation
(** Read the primary v4 snapshot and complete committed settlement WAL under
    the lane owner lock, replaying the WAL through the typed state machine only
    in memory. This function never checkpoints, rewrites, creates, or compacts
    queue files, so dashboard observation cannot mutate the state it reports. *)

val load_state_result :
  base_path:string -> keeper_name:string -> (Keeper_event_queue_state.t, string) result
(** Strict state read used by tests and operator projection. A malformed v4
    envelope is an [Error], never an empty queue. Retired-epoch residue is not
    consulted by this authority path and cannot block a current lane.
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
  | Enqueued of Keeper_event_queue.stimulus
  | Already_present of Keeper_event_queue.stimulus

val enqueue_stimulus_if_absent_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  Keeper_event_queue.stimulus ->
  (enqueue_stimulus_result, string) result
(** Atomically enqueue only when the same typed stimulus is absent from the
    full durable state: pending, active leases, and transition outbox. Both
    successful variants carry the exact durable stimulus: the newly committed
    value for [Enqueued], or the previously committed value for
    [Already_present]. *)

val enqueue_stimuli_if_absent_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  Keeper_event_queue.stimulus list ->
  (enqueue_stimulus_result list, string) result
(** Batch form of {!enqueue_stimulus_if_absent_result}. Every input identity
    is resolved against pending, active leases, outbox, and earlier items in
    this batch inside one queue transaction. A conflict commits nothing. *)

val persist_snapshot :
  base_path:string -> keeper_name:string -> (unit -> Keeper_event_queue.t) -> unit

val drop_by_post_id :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  post_id:string ->
  unit ->
  (Keeper_event_queue.stimulus list, string) result

val fleet_summary_json : now:float -> base_path:string -> Yojson.Safe.t

module For_testing : sig
  val with_before_reaction_coordination_lock_hook :
    (unit -> unit) -> (unit -> 'a) -> 'a
  (** Install a scoped hook immediately before durable coordination-lock
      acquisition.  Tests use it as a barrier; production always observes the
      default no-op hook. *)
end
