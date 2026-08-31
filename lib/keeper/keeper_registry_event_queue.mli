(** Per-keeper event-queue access.

    SSOT for enqueueing / draining the per-keeper stimulus queue.
    The MASC-owned v2 envelope is authoritative.  Mutations commit that one
    durable state first, then publish its pending projection into the
    entry-owned [event_queue : Keeper_event_queue.t Atomic.t].  No central
    registry Atomic is touched. *)

type accepted_cancellation = Keeper_event_queue_persistence.accepted_cancellation =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; operator_operation_id : string
  ; reason : string
  }

type accepted_transfer = Keeper_event_queue_persistence.accepted_transfer =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; operator_operation_id : string
  ; from_keeper : string
  ; to_keeper : string
  ; target_trace_id : Keeper_id.Trace_id.t
  }

type source_terminal_receipt = Keeper_event_queue_persistence.source_terminal_receipt =
  | Fusion_terminal of Keeper_event_queue.fusion_completion
  | Hitl_terminal of Keeper_event_queue.hitl_resolution
  | Turn_completed
  | Turn_attempt_terminal of { detail : string }

type accepted_source_terminal = Keeper_event_queue_persistence.accepted_source_terminal =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
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

type transfer_pending_error =
  | Transfer_pending_storage_error of string
  | Transfer_pending_shutdown_reserved of Keeper_shutdown_types.Operation_id.t

val transfer_pending_error_to_string : transfer_pending_error -> string

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
  now:float ->
  ready:(Keeper_event_queue.stimulus -> bool) ->
  (Keeper_event_queue.stimulus option, string) result

val select_when_result :
  base_path:string ->
  string ->
  now:float ->
  ready:(Keeper_event_queue.stimulus -> bool) ->
  (Keeper_event_queue_state.pending_selection option, string) result

val pending_selections_result :
  base_path:string ->
  string ->
  (Keeper_event_queue_state.pending_selection list, string) result
(** Read every exact pending selection in durable queue order without
    consuming it. *)

val validate_pending_selection_result :
  base_path:string ->
  string ->
  selection:Keeper_event_queue_state.pending_selection ->
  (unit, string) result

val ack_pending_result :
  base_path:string ->
  string ->
  selection:Keeper_event_queue_state.pending_selection ->
  (unit, string) result

val cancel_pending_accepted_result :
  base_path:string ->
  string ->
  applied_at:float ->
  cancellation:accepted_cancellation ->
  (transition_result, string) result
(** Commit an exact pending accepted cancellation and publish the post-commit
    pending projection when the owner currently has a live registry lane. *)

val cancel_scheduled_wakes_result :
  base_path:string ->
  string ->
  applied_at:float ->
  schedule_ids:string list ->
  reason:string ->
  (int, string) result
(** Cancel every pending [Schedule_due] stimulus whose [schedule_id] is in the
    given set, through the exact accepted-cancellation transition. Returns the
    number of pending entries removed. This is the cancel-propagation half of
    task-370: a cancelled schedule's enqueued utterances leave the durable
    queue at the cancel boundary instead of riding the wake path. *)

val drain_owner_absent_pending_result :
  base_path:string ->
  string ->
  applied_at:float ->
  reason:string ->
  (int, string) result
(** Cancel every pending stimulus owned by a name the Keeper store does not
    know. No maintenance cycle can make that wait productive; retaining it
    produced 881 retained visits for one stale queue and a 913-error day.
    Returns the number of pending entries removed. *)

val transfer_pending_accepted_result :
  ?intake_token:Keeper_shutdown_intake_fence.intake_token ->
  base_path:string ->
  string ->
  applied_at:float ->
  transfer:accepted_transfer ->
  (transition_result, transfer_pending_error) result
(** Commit an exact pending accepted transfer transition and publish the
    post-commit source pending projection when the owner is registered. The
    source mutation owns the same durable-intake authority as schedule retry
    repair, so the resolved owner cannot change between retry validation and
    its acceptance commit. A live [intake_token] lets a transaction preserve
    a wider source-and-target intake fence without reacquiring this mutex. *)

val ack_pending_source_terminal_result :
  base_path:string ->
  string ->
  acked_at:float ->
  source_terminal:accepted_source_terminal ->
  (source_ack_result, string) result
(** Commit one exact terminal source ACK, publish the post-commit pending
    projection when the owner is registered, and project its durable reaction
    evidence before another source can settle. *)

val terminalize_pending_turn_attempt_result :
  base_path:string ->
  string ->
  applied_at:float ->
  selection:Keeper_event_queue_state.pending_selection ->
  detail:string ->
  (source_ack_result, string) result
(** Commit a source-bearing terminal receipt for one failed admitted turn,
    publish the post-commit pending projection, and project its durable reaction
    evidence before another source can settle. *)

val terminalize_pending_turn_completed_result :
  base_path:string ->
  string ->
  applied_at:float ->
  selection:Keeper_event_queue_state.pending_selection ->
  (source_ack_result, string) result
(** Commit a source-bearing completion receipt for one successful admitted
    turn, publish the post-commit pending projection, and project its durable
    reaction evidence before another source can settle. *)

(** Enqueue a stimulus on the keeper's event queue. An owner not registered yet
    may receive durable work so a later lane can replay it. A surrounding
    durable-intake fence supplies [intake_token]; otherwise this function
    acquires the Keeper fence itself. *)
val enqueue :
  ?intake_token:Keeper_shutdown_intake_fence.intake_token ->
  base_path:string -> string -> Keeper_event_queue.stimulus -> unit

val enqueue_durable_result :
  ?intake_token:Keeper_shutdown_intake_fence.intake_token
  -> base_path:string
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
  ?intake_token:Keeper_shutdown_intake_fence.intake_token
  -> base_path:string
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

type transfer_target_error =
  | Transfer_target_name_mismatch of
      { expected : string
      ; actual : string
      }
  | Transfer_target_metadata_read_failed of string
  | Transfer_target_metadata_absent
  | Transfer_target_trace_changed

val transfer_target_error_to_string : transfer_target_error -> string

type transfer_projection_result =
  | Transfer_projection_committed
  | Transfer_projection_already_committed
  | Transfer_projection_storage_error of string
  | Transfer_projection_target_unavailable of transfer_target_error
  | Transfer_projection_shutdown_reserved of Keeper_shutdown_types.Operation_id.t

val enqueue_stimulus_durable_result :
  ?intake_token:Keeper_shutdown_intake_fence.intake_token
  -> base_path:string
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
  ?intake_token:Keeper_shutdown_intake_fence.intake_token
  -> base_path:string
  -> string
  -> transfer:accepted_transfer
  -> transfer_projection_result
(** Strict target transfer projection. The exact source and operation identity
    are durably accounted in the target queue state before the pending
    projection becomes visible. Accounting survives consumption, and an exact
    durable replay converges even after the target identity rotates. A first
    target effect is authorized against the recorded generation/trace; a target
    shutdown reservation or identity mismatch rejects the
    projection before any durable mutation. A live [intake_token] lets the
    caller hold that target fence before committing a corresponding source
    ACK. *)

type hitl_resolution_enqueue_error =
  | Hitl_recipient_absent
      (** No Keeper exists with the addressed name, so the resolution wake
          can never be consumed. Callers settle the durable delivery instead
          of replaying a permanent failure at every boot. *)
  | Hitl_enqueue_failed of string

val hitl_resolution_enqueue_error_to_string :
  hitl_resolution_enqueue_error -> string

val enqueue_hitl_resolution_durable_result :
  base_path:string
  -> keeper_name:string
  -> approval_id:string
  -> decision:Keeper_event_queue.hitl_resolution_decision
  -> channel:Keeper_continuation_channel.t
  -> (unit, hitl_resolution_enqueue_error) result
(** Build and durably enqueue the canonical [Hitl_resolved] stimulus. This is
    the single construction boundary shared by the server composition root and
    nonblocking-approval tests; callers may signal a live fiber only after this
    function returns [Ok ()]. An absent recipient is reported as
    [Hitl_recipient_absent] so callers can settle the obligation instead of
    treating it as a transient delivery failure. *)

(** Read-only snapshot of the keeper's queue. If the keeper is not registered,
    read the durable snapshot so diagnostics still expose pending replay.
    Durable read failures remain explicit. *)
val snapshot_result :
  base_path:string -> string -> (Keeper_event_queue.t, string) result

val durable_state_result :
  base_path:string -> string -> (Keeper_event_queue_state.t, string) result
(** Read the authoritative durable queue state, including pending entries,
    transition outbox, and projected typed dispositions. Unlike
    {!snapshot_result}, this never returns a process-local Atomic projection.
    Absence of both the current snapshot and transition WAL is the valid empty
    state used before the first durable enqueue. *)

val reprioritize_pending_result :
  base_path:string ->
  string ->
  selection:Keeper_event_queue_state.pending_selection ->
  urgency:Keeper_event_queue.urgency ->
  (int64, string) result

val defer_pending_result :
  base_path:string ->
  string ->
  selection:Keeper_event_queue_state.pending_selection ->
  (int64, string) result
(** Durable queue-tail rotation for a transiently blocked exact source. *)

val drop_by_post_id :
  base_path:string
  -> string
  -> post_id:string
  -> (Keeper_event_queue.stimulus list, string) result
(** Remove matching stimuli from the live queue plus durable pending/in-flight
    snapshots, returning the exact stimuli that were dropped. Returns [Error _]
    when durable removal fails so callers do not clear recovery state while a
    replayable stimulus remains on disk. *)
