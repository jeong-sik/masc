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

type exact_write_outcome =
  | Fsync_completed
  | Visible_sync_unconfirmed of string
(** [Fsync_completed] means the payload and parent-directory [Unix.fsync]
    calls both returned successfully. It is the process-restart dispatch
    fence, not a hardware/power-loss persistence or Darwin [F_FULLFSYNC]
    guarantee. [Visible_sync_unconfirmed _] means rename is visible but the
    parent sync did not complete. *)

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
  | Cancel_accepted of accepted_cancellation
  | Transfer_accepted of accepted_transfer
  | Ack_source_terminal of accepted_source_terminal

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
  (Keeper_event_queue.stimulus option, string) result

val validate_pending_selection_result :
  base_path:string ->
  keeper_name:string ->
  selection:Keeper_event_queue.stimulus ->
  (unit, string) result

val ack_pending_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  selection:Keeper_event_queue.stimulus ->
  unit ->
  (unit, string) result

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
