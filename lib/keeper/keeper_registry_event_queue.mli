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

type escalation_reason = Keeper_event_queue_persistence.escalation_reason =
  | Failure_judgment_requested
  | Failure_judgment_boundary_failed of { detail : string }
  | Failure_judgment_external_input_requested of
      { judge_runtime_id : string
      ; rationale : string
      }

type settlement = Keeper_event_queue_persistence.settlement =
  | Ack
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

val lease_stimuli : lease -> Keeper_event_queue.stimulus list
val lease_kind : lease -> Keeper_event_queue_persistence.lease_kind

val active_lease_result :
  base_path:string -> string -> (lease option, string) result

val transition_outbox_result :
  base_path:string -> string -> (outbox_entry list, string) result

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
