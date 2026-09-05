(** Pure durable state machine for one Keeper event queue owner.

    The current snapshot and full-pre-state transition WAL jointly form the
    durable authority. This module performs no I/O; persistence supplies the
    atomic file boundary and publishes [pending] into the live registry only
    after a durable commit. *)

type accepted_cancellation =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; operator_operation_id : string
  ; reason : string
  }
(** Exact operator authority for terminally cancelling one accepted event.
    [source_incarnation] fences the observed paused owner;
    [operator_operation_id] makes replay/conflict explicit. *)

type accepted_transfer =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; operator_operation_id : string
  ; from_keeper : string
  ; to_keeper : string
  ; target_trace_id : Keeper_id.Trace_id.t
  }
(** Exact causal authority for terminally transferring one accepted event.
    [target_trace_id] prevents delayed outbox replay
    from projecting into a purged or same-name replacement Keeper. *)

type source_terminal_receipt =
  | Fusion_terminal of Keeper_event_queue.fusion_completion
  | Hitl_terminal of Keeper_event_queue.hitl_resolution
  | Turn_completed
  | Turn_attempt_terminal of { detail : string }
(** Closed terminal source evidence. Fusion and HITL completion are intrinsically
    represented by their durable event payload. [Turn_completed] records a
    successful admitted turn; [Turn_attempt_terminal] records that one admitted
    turn ended without a successful result. In both cases the exact
    source remains in the transition receipt instead of being discarded by a
    raw ACK. [detail] is diagnostic only and carries no transition authority. *)

type accepted_source_terminal =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; operator_operation_id : string
  ; source_receipt : source_terminal_receipt
  }

type transition =
  | Cancel_accepted of accepted_cancellation
  | Transfer_accepted of accepted_transfer
  | Ack_source_terminal of accepted_source_terminal

val transition_source : transition -> Keeper_event_queue.stimulus

type transition_receipt =
  { transition_id : string
  ; event_id : string
  ; applied_at : float
  ; transition : transition
  }

type projected_disposition_kind =
  | Projected_cancel of { reason_ref : string }
  | Projected_transfer of
      { from_keeper : string
      ; to_keeper : string
      ; target_trace_id : Keeper_id.Trace_id.t
      }
  | Projected_fusion_terminal
  | Projected_hitl_terminal
  | Projected_turn_completed
  | Projected_turn_attempt_terminal

type projected_source_kind =
  | Source_board_signal
  | Source_board_attention
  | Source_bootstrap
  | Source_fusion_completed
  | Source_schedule_due
  | Source_connector_attention
  | Source_hitl_resolved
  | Source_ask_answered
  | Source_completion_authority_rejected
  | Source_task_cancelled
  | Source_workspace_message
  | Source_delegate_completed
  | Source_composition_completed

val projected_source_kind_to_string : projected_source_kind -> string

type projected_disposition_witness =
  { transition_id : string
  ; event_id : string
  ; applied_at : float
  ; operator_operation_id : string
  ; transition_ref : string
  ; source_ref : string
  ; post_id : string
  ; urgency : Keeper_event_queue.urgency
  ; source_arrived_at : float
  ; source_kind : projected_source_kind
  ; source_incarnation : int64
  ; kind : projected_disposition_kind
  }

type durable_disposition =
  | Current_receipt of transition_receipt
  | Projected_witness of projected_disposition_witness

type outbox_entry =
  { receipt : transition_receipt
  ; stimuli : Keeper_event_queue.stimulus list
  }

type t

type pending_selection =
  { source : Keeper_event_queue.stimulus
  ; admitted_revision : int64
  ; attention_retentions : int
  }
(** One exact durable queue entry. [admitted_revision] records the durable
    transform that admitted the snapshot; entries admitted by the same
    transform may share it, so exact selection combines it with
    {!source_snapshot_ref}. *)

type transition_result =
  | Transition_applied of transition_receipt
  | Transition_already_applied of transition_receipt

type transfer_projection_result =
  | Transfer_projected
  | Transfer_already_projected

val empty : t
val revision : t -> int64
val pending : t -> Keeper_event_queue.t
val pending_selections : t -> pending_selection list
(** FIFO pending entries with their exact source incarnation authority. *)

val source_snapshot_ref : Keeper_event_queue.stimulus -> string
(** Stable SHA-256 reference derived from the exact typed source snapshot. It
    exposes no raw payload bytes; [source_incarnation] separately identifies a
    later reinsertion of the same snapshot. *)

val disposition_reason_ref : string -> string
(** Domain-separated digest for exact cancellation-reason replay matching. *)

val resolve_pending_selection :
  source_ref:string ->
  source_incarnation:int64 ->
  t ->
  (pending_selection, string) result
(** Resolve one exact pending source without consulting the global queue
    revision or queue position. *)

val last_transition : t -> transition_receipt option
val projected_dispositions : t -> durable_disposition list
(** Newest-first projected dispositions. The current receipt remains full;
    displaced history is a compact exact-replay witness. *)

val transition_receipt_is_projected : transition_receipt -> t -> bool
(** Exact full-receipt or compact-fingerprint membership used by WAL replay. *)

val prior_disposition_by_operation_id :
  string -> t -> durable_disposition option
(** Return the unique durable disposition for an operator operation ID from
    either the current outbox or projected history. *)

val transition_outbox : t -> outbox_entry list
val accepted_transfer_projections : t -> accepted_transfer list

val with_pending : Keeper_event_queue.t -> t -> t
val with_revision : int64 -> t -> t

val peek_when :
  now:float ->
  ready:(Keeper_event_queue.stimulus -> bool) ->
  t ->
  Keeper_event_queue.stimulus option
(** [now] ages a waiting [Low] stimulus into [Normal] priority past
    {!Keeper_event_queue.low_to_normal_aging_threshold_sec} (#31597). *)

val select_when :
  now:float ->
  ready:(Keeper_event_queue.stimulus -> bool) ->
  t ->
  pending_selection option
(** See {!peek_when} on [now]. *)

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

val note_attention_retention :
  selection:pending_selection ->
  t ->
  ((t * (pending_selection * int)), string) result
(** Count one checkpoint-yield retention on the exact selected entry and
    rewrite it with the new count. The returned selection carries the count;
    the caller's pre-bump snapshot no longer validates structurally and must
    not be reused against the queue. *)

val reprioritize_pending :
  selection:pending_selection ->
  urgency:Keeper_event_queue.urgency ->
  t ->
  (t * int64, string) result
(** Change only the exact selected source priority. A real change receives the
    next source incarnation; unrelated pending entries retain theirs. *)

val defer_pending :
  selection:pending_selection ->
  t ->
  (t * int64, string) result
(** Move one exact selected source to the back of its current urgency lane and
    assign a new source incarnation. This is the durable fairness primitive for
    transient failures: no source is lost, but it cannot monopolize the head of
    the active queue while independent work is waiting. *)

val cancel_pending_accepted :
  applied_at:float ->
  cancellation:accepted_cancellation ->
  t ->
  (t * transition_result, string) result
(** Atomically apply the exact pending cancellation. The source incarnation and
    owner generation are checked before removal. The transition is committed
    through a source-bearing WAL outbox entry by persistence. *)

val transfer_pending_accepted :
  applied_at:float ->
  transfer:accepted_transfer ->
  t ->
  (t * transition_result, string) result
(** Atomically apply the exact pending transfer. The source incarnation and owner
    generation are checked before removal, and the source-bearing WAL remains
    the replay authority until the target projection completes. *)

val ack_pending_source_terminal :
  applied_at:float ->
  source_terminal:accepted_source_terminal ->
  t ->
  (t * transition_result, string) result
(** ACK one exact pending event. Intrinsic product-terminal receipts must match
    the source payload exactly. A turn-attempt terminal receipt carries the
    exact source itself; its detail is diagnostic and never admission
    authority. *)

val terminalize_pending_turn_attempt :
  applied_at:float ->
  selection:pending_selection ->
  detail:string ->
  t ->
  (t * transition_result, string) result
(** End one admitted turn attempt with a deterministic operation identity
    derived from the exact selected queue snapshot and owner generation.
    Repeating the same request after WAL projection returns its original
    receipt, while a later selection of the same source is a new attempt;
    diagnostic [detail] never participates in admission or idempotency. *)

val terminalize_pending_turn_completed :
  applied_at:float ->
  selection:pending_selection ->
  t ->
  (t * transition_result, string) result
(** Commit typed completion evidence for one admitted turn. Completion and
    failure share one deterministic per-attempt operation identity, so a stale
    contradictory settlement fails closed instead of replacing the first
    durable outcome. *)

val accepted_pending_cancellation_replay :
  accepted_cancellation ->
  t ->
  (transition_receipt option, string) result
(** Look up an already committed pending cancellation by its stable operator
    operation ID and exact source-bearing transition. *)

val accepted_pending_transfer_replay :
  accepted_transfer ->
  t ->
  (transition_receipt option, string) result
(** Look up an already committed pending transfer by its stable operator
    operation ID and exact source-bearing transition. *)

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
(** Accept only [Fusion_completed] or [Hitl_resolved] and retain their exact
    typed terminal payload. *)

val mark_transition_projected : transition_id:string -> t -> (t, string) result
(** Atomically retire a durable outbox entry after an external projector has
    materialized its stable [event_id]. The latest receipt remains visible and
    every older operator disposition remains in the replay ledger; ordinary
    non-disposition history is not retained indefinitely. Unknown transition
    ids fail closed. *)

val remove_by_post_id :
  Keeper_event_queue.post_id -> t -> Keeper_event_queue.stimulus list * t

val transition_receipt_equal : transition_receipt -> transition_receipt -> bool
val transition_receipt_to_yojson : transition_receipt -> Yojson.Safe.t
val transition_receipt_of_yojson : Yojson.Safe.t -> (transition_receipt, string) result
val outbox_entry_to_yojson : outbox_entry -> Yojson.Safe.t
val outbox_entry_of_yojson : Yojson.Safe.t -> (outbox_entry, string) result
val replay_transition_outbox_entry : outbox_entry -> t -> (t, string) result
(** Replay one current source-bearing committed transition. *)
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result

val schema : string
(** ["keeper.event_queue.state.v18"] is the only accepted schema. *)
