(** Durable per-Keeper Event Layer state.

    Current writes use the [keeper.event_queue.state.v12]
    [event-queue-v12.json] envelope: revision, pending stimuli, the latest
    projected transition, an operation-indexed ledger of older projected
    dispositions, at most one unprojected transition, and durable
    accepted-transfer target projections. Only this schema and the
    [event-queue-transitions-v2.jsonl] WAL are accepted. Retired snapshot, WAL,
    receipt, and sidecar paths are not inspected or treated as queue authority. *)

type owner_identity
type owner_identity_error

val resolve_owner_identity :
  base_path:string ->
  keeper_name:string ->
  (owner_identity, owner_identity_error) result
(** Resolve the canonical process-local owner identity shared by every durable
    event-queue operation. The representation and owner-lock implementation
    remain private to [masc.keeper_runtime]. *)

val owner_identity_error_to_string : owner_identity_error -> string
val owner_identity_equal : owner_identity -> owner_identity -> bool
val owner_identity_hash : owner_identity -> int
val owner_identity_base_path : owner_identity -> string
val owner_identity_keeper_name : owner_identity -> string

type selection_kind = Keeper_event_queue_state.selection_kind =
  | Single
  | Board_batch

type pending_selection = Keeper_event_queue_state.pending_selection =
  { source_revision : int64
  ; kind : selection_kind
  ; stimuli : Keeper_event_queue.stimulus list
  }


type requeue_reason = Keeper_event_queue_state.requeue_reason =
  | Cycle_busy
  | Turn_not_scheduled
  | Rotate_now
  | Cancelled
  | Cycle_crashed
  | Registration_recovery
  | Retry_after_observed
  | Context_compaction_retry

type exact_execution_terminal_cause = Keeper_event_queue_state.exact_execution_terminal_cause =
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

type exact_execution_terminal = Keeper_event_queue_state.exact_execution_terminal =
  { cause : exact_execution_terminal_cause
  ; slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
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
  | Transcript_corruption_requires_reset of { detail : string }

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

type transition = Keeper_event_queue_state.transition =
  | Ack
  | Manual_compaction_committed of
      { commit : Keeper_event_queue_state.manual_compaction_commit
      ; followup : Keeper_event_queue_state.manual_compaction_followup
      }
  | No_compaction of no_compaction
  | Cancel_accepted of accepted_cancellation
  | Transfer_accepted of accepted_transfer
  | Ack_source_terminal of accepted_source_terminal
  | Requeue of requeue_reason
  | Escalate of
      { reason : escalation_reason
      ; successor : Keeper_event_queue.stimulus option
      }

type transition_receipt = Keeper_event_queue_state.transition_receipt
type outbox_entry = Keeper_event_queue_state.outbox_entry

type transition_result =
  | Transition_applied of transition_receipt
  | Transition_already_applied of transition_receipt
  | Transition_committed_followup_failed of
      { receipt : transition_receipt
      ; stage : [ `Checkpoint | `Wal_compaction | `Projection ]
      ; detail : string
      }

type transfer_projection_result =
  | Transfer_projected
  | Transfer_already_projected

val load_result :
  base_path:string -> keeper_name:string -> (Keeper_event_queue.t, string) result
(** Strict pending projection after durable transition-WAL replay. Durable read
    failures remain explicit. *)

val load_pending_result :
  base_path:string -> keeper_name:string -> (Keeper_event_queue.t, string) result
(** Strict pending projection. Durable read failures remain explicit. *)

val peek_when_result :
  base_path:string ->
  keeper_name:string ->
  ready:(Keeper_event_queue.stimulus -> bool) ->
  (pending_selection option, string) result

val validate_pending_selection_result :
  base_path:string ->
  keeper_name:string ->
  selection:pending_selection ->
  (unit, string) result

type pending_ack_result =
  | Ack_applied
  | Ack_applied_followup_failed of string

val ack_pending_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  selection:pending_selection ->
  unit ->
  (pending_ack_result, string) result
(** Remove the exact pending selection. [Ack_applied_followup_failed] means the
    snapshot already committed the removal but transition-WAL cleanup or
    post-commit projection failed; callers must not apply the ACK or execute
    the source again. *)

val retry_pending_ack_followup_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  unit ->
  (unit, string) result
(** Retry only post-commit WAL cleanup and publish the already-committed
    pending projection. Never applies an ACK transition. *)

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
val load_snapshot_pair_with_errors :
  base_path:string -> keeper_name:string -> snapshot_pair_with_errors

val load_state_result :
  base_path:string -> keeper_name:string -> (Keeper_event_queue_state.t, string) result
(** Strict state read used by tests and operator projection. A malformed
    current envelope or stale/unknown schema is an [Error], never an empty
    queue. Committed current-schema WAL rows are replayed idempotently. A row
    already represented by the durable projected witness is compacted; an
    unprojected source-bearing row remains authoritative until the reaction
    projector records and retires it. *)

val cancel_pending_accepted_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  current_owner_nonce:int ->
  applied_at:float ->
  cancellation:accepted_cancellation ->
  unit ->
  (transition_result, string) result
(** Append and fsync the canonical source-bearing cancellation transition before
    checkpointing removal of the exact pending source. WAL replay can complete
    the transition from the pre-removal state after a crash. *)

val transfer_pending_accepted_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  current_owner_nonce:int ->
  applied_at:float ->
  transfer:accepted_transfer ->
  unit ->
  (transition_result, string) result
(** Append and fsync the canonical source-bearing transfer transition before
    checkpointing removal of the exact pending source. *)

val ack_pending_source_terminal_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  current_owner_nonce:int ->
  acked_at:float ->
  source_terminal:accepted_source_terminal ->
  unit ->
  (transition_result, string) result
(** Append and fsync the canonical source-bearing ACK transition before
    checkpointing removal of the exact pending source. *)

val project_transition_outbox_result :
  append_before_retire:(outbox_entry -> (unit, string) result) ->
  base_path:string ->
  keeper_name:string ->
  (unit, string) result
(** Read the single pending transition under the canonical lane identity,
    invoke the supplied ledger append, and retire only after that append
    succeeds. Raw outbox entries and the retirement primitive are not exported
    independently. *)

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
    full durable state: pending and transition outbox. *)

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

module For_testing : sig
  val force_transition_wal_compaction_failures : int -> unit
  (** Force the next N transition-WAL compactions to fail after the snapshot
      commit, for ACK post-commit recovery tests. *)
end

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
  | Recoverable
  | Retained_disabled
  | Paused_dead
  | Shutdown_fenced
  | Lifecycle_unknown of string

(** Fleet projection split by the caller's canonical durable owner-lifecycle
    read. [Runnable] requires a live owner fiber; [Recoverable] is permitted
    owner truth with durable demand but no live fiber. Disabled, paused/dead,
    and shutdown-fenced owners remain distinct closed variants. Queue
    persistence deliberately does not infer owner truth from event contents or
    elapsed time. *)
val fleet_summary_json :
  now:float ->
  base_path:string ->
  owner_lifecycle:(keeper_name:string -> owner_lifecycle) ->
  Yojson.Safe.t
