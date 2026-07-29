(** Per-keeper event-queue access.

    SSOT for enqueueing / draining the per-keeper stimulus queue.
    The MASC-owned v2 envelope is authoritative.  Mutations commit that one
    durable state first, then publish its pending projection into the
    entry-owned [event_queue : Keeper_event_queue.t Atomic.t].  No central
    registry Atomic is touched. *)

type pending_selection = Keeper_event_queue_persistence.pending_selection =
  { source_revision : int64
  ; kind : Keeper_event_queue_persistence.selection_kind
  ; stimuli : Keeper_event_queue.stimulus list
  }


type accepted_cancellation = Keeper_event_queue_persistence.accepted_cancellation =
  { source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; owner_nonce : int
  ; operator_operation_id : string
  ; reason : string
  }

type accepted_transfer = Keeper_event_queue_persistence.accepted_transfer =
  { source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; owner_nonce : int
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
  ; owner_nonce : int
  ; operator_operation_id : string
  ; source_receipt : source_terminal_receipt
  }

type transition = Keeper_event_queue_persistence.transition =
  | Cancel_accepted of accepted_cancellation
  | Transfer_accepted of accepted_transfer
  | Ack_source_terminal of accepted_source_terminal

type transition_receipt = Keeper_event_queue_persistence.transition_receipt
type outbox_entry = Keeper_event_queue_persistence.outbox_entry

type transition_result = Keeper_event_queue_persistence.transition_result =
  | Transition_applied of transition_receipt
  | Transition_already_applied of transition_receipt
  | Transition_committed_followup_failed of
      { receipt : transition_receipt
      ; stage : [ `Checkpoint | `Wal_compaction | `Projection ]
      ; detail : string
      }

type source_ack_result =
  | Acked of transition_receipt
  | Already_acked of transition_receipt
  | Ack_committed_followup_failed of
      { receipt : transition_receipt
      ; stage : [ `Checkpoint | `Wal_compaction | `Projection ]
      ; detail : string
      }


val peek_when_result :
  base_path:string ->
  string ->
  ready:(Keeper_event_queue.stimulus -> bool) ->
  (pending_selection option, string) result

val validate_pending_selection_result :
  base_path:string ->
  string ->
  selection:pending_selection ->
  (unit, string) result

val ack_pending_result :
  base_path:string ->
  string ->
  selection:pending_selection ->
  (unit, string) result

val cancel_pending_accepted_result :
  base_path:string ->
  string ->
  current_owner_nonce:int ->
  applied_at:float ->
  cancellation:accepted_cancellation ->
  (transition_result, string) result
(** Commit an exact pending accepted cancellation and publish the post-commit
    pending projection when the owner currently has a live registry lane. *)

val transfer_pending_accepted_result :
  base_path:string ->
  string ->
  current_owner_nonce:int ->
  applied_at:float ->
  transfer:accepted_transfer ->
  (transition_result, string) result
(** Commit an exact pending accepted transfer transition and publish the
    post-commit source pending projection when the owner is registered. *)

val ack_pending_source_terminal_result :
  base_path:string ->
  string ->
  current_owner_nonce:int ->
  acked_at:float ->
  source_terminal:accepted_source_terminal ->
  (source_ack_result, string) result
(** Commit one exact terminal source ACK and publish the post-commit pending
    projection when the owner is registered. *)

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
    pending and the transition outbox. This explicit-result
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
    read the durable snapshot so diagnostics still expose pending replay.
    Durable read failures remain explicit. *)
val snapshot_result :
  base_path:string -> string -> (Keeper_event_queue.t, string) result

val drop_by_post_id :
  base_path:string
  -> string
  -> post_id:string
  -> (Keeper_event_queue.stimulus list, string) result
(** Remove matching stimuli from the live queue plus durable pending/in-flight
    snapshots, returning the exact stimuli that were dropped. Returns [Error _]
    when durable removal fails so callers do not clear recovery state while a
    replayable stimulus remains on disk. *)
