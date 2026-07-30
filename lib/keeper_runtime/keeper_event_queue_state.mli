(** Pure durable state machine for one Keeper event queue owner.

    [event-queue-v14.json] is the sole authority for pending stimuli and
    source-bearing transition projection work. This module performs no I/O;
    persistence supplies the atomic file boundary and publishes [pending] into
    the live registry only after a durable commit. *)

type accepted_cancellation =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; owner_nonce : int
  ; operator_operation_id : string
  ; reason : string
  }
(** Exact operator authority for terminally cancelling one accepted event.
    [source_incarnation] and [owner_nonce] fence the observed paused owner;
    [operator_operation_id] makes replay/conflict explicit. *)

type accepted_transfer =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
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
  | Turn_attempt_terminal of { detail : string }
(** Closed terminal source evidence. The first three families are intrinsically
    represented by their durable event payload. [Turn_attempt_terminal] records
    that one admitted turn ended without durable compaction progress; the exact
    source remains in the transition receipt instead of being discarded by a
    raw ACK. [detail] is diagnostic only and carries no transition authority. *)

type accepted_source_terminal =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; owner_nonce : int
  ; operator_operation_id : string
  ; source_receipt : source_terminal_receipt
  }

type transition =
  | Cancel_accepted of accepted_cancellation
  | Transfer_accepted of accepted_transfer
  | Ack_source_terminal of accepted_source_terminal

type transition_receipt =
  { transition_id : string
  ; event_id : string
  ; applied_at : float
  ; transition : transition
  }

type outbox_entry =
  { receipt : transition_receipt
  ; stimuli : Keeper_event_queue.stimulus list
  }

type t

type pending_selection =
  { source : Keeper_event_queue.stimulus
  ; admitted_revision : int64
  }
(** One exact durable queue entry. [admitted_revision] identifies the source
    incarnation without making later unrelated queue changes invalidate it. *)

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

val last_transition : t -> transition_receipt option
val projected_dispositions : t -> transition_receipt list
(** Newest-first projected operator dispositions, including
    [last_transition] when it is itself an operator disposition. *)

val projected_transition_receipts : t -> transition_receipt list
(** The latest projected transition plus every older operator disposition
    witness retained for exact operation replay. *)

val transition_outbox : t -> outbox_entry list
val accepted_transfer_projections : t -> accepted_transfer list

val with_pending : Keeper_event_queue.t -> t -> t
val with_revision : int64 -> t -> t

val peek_when :
  ready:(Keeper_event_queue.stimulus -> bool) ->
  t ->
  Keeper_event_queue.stimulus option

val select_when :
  ready:(Keeper_event_queue.stimulus -> bool) -> t -> pending_selection option

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

val cancel_pending_accepted :
  current_owner_nonce:int ->
  applied_at:float ->
  cancellation:accepted_cancellation ->
  t ->
  (t * transition_result, string) result
(** Atomically apply the exact pending cancellation. The source incarnation and
    owner generation are checked before removal. The transition is committed
    through a source-bearing WAL outbox entry by persistence. *)

val transfer_pending_accepted :
  current_owner_nonce:int ->
  applied_at:float ->
  transfer:accepted_transfer ->
  t ->
  (t * transition_result, string) result
(** Atomically apply the exact pending transfer. The source incarnation and owner
    generation are checked before removal, and the source-bearing WAL remains
    the replay authority until the target projection completes. *)

val ack_pending_source_terminal :
  current_owner_nonce:int ->
  applied_at:float ->
  source_terminal:accepted_source_terminal ->
  t ->
  (t * transition_result, string) result
(** ACK one exact pending event. Intrinsic product-terminal receipts must match
    the source payload exactly. A turn-attempt terminal receipt carries the
    exact source itself; its detail is diagnostic and never admission
    authority. *)

val terminalize_pending_turn_attempt :
  current_owner_nonce:int ->
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
(** Accept only [Fusion_completed], [Bg_completed], or [Hitl_resolved] and
    retain their exact typed terminal payload. *)

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
(** ["keeper.event_queue.state.v14"] is the only accepted schema. *)
