(** Event Layer queue for the keeper heartbeat loop.

    Models the contract verified in
    [specs/keeper-state-machine/KeeperEventQueue.tla]: enqueue is a
    side-effect-free Event Layer operation, the Policy Layer drains
    pending stimuli once it gets a turn, and dedup/urgency are
    bookkeeping concerns that never delay an [enqueue].

    This module is data only. The enqueue side is wired:
    [keeper_keepalive_signal.ml] calls [Keeper_registry_event_queue.enqueue]
    before the wakeup flag flips (RFC-0020 Rule 1). On the intake side,
    [keeper_heartbeat_stimulus_intake.ml] peeks at the earliest ready stimulus,
    validates that same immutable source immediately before dispatch, and
    removes it only through an exact ACK after the turn reaches an
    acknowledging outcome. The per-Keeper wakeup atomic cuts the configured
    heartbeat sleep, and no policy layer may suppress the following cycle. *)

type urgency =
  | Immediate  (** operator commands and other latency-critical signals *)
  | Normal     (** board posts, mentions *)
  | Low        (** background polling, telemetry-driven nudges *)

type post_id = string
(** Producer-supplied identity component used by
    {!stimulus_identity_equal}.

    The runtime uses the originating board post id, the mention
    target id, or the operator directive token. The queue does
    not interpret the value beyond equality. *)

type board_stimulus_kind =
  | Post_created
  | Comment_added
  | Reaction_changed of board_reaction_change
  | Vote_cast of board_vote_change
      (** A vote landed on the post or on one of its comments. The queue is a
          leaf, so the target and direction are mirrored here and converted
          at the keeper boundary like [board_reaction_change]. *)

and board_reaction_target_type =
  | Reaction_post
  | Reaction_comment

and board_reaction_change = {
  target_type : board_reaction_target_type;
  target_id : string;
  user_id : string;
  emoji : string;
  reacted : bool;
}

and board_vote_target =
  | Vote_on_post of string
  | Vote_on_comment of string

and board_vote_direction =
  | Vote_up
  | Vote_down

and board_vote_change = {
  target : board_vote_target;
  target_author : string;
  voter : string;
  direction : board_vote_direction;
}

type board_stimulus = {
  kind : board_stimulus_kind;
  author : string;
  title : string;
  content : string;
  hearth : string option;
  updated_at : float option;
}
(** Typed board-signal payload carried end-to-end (RFC-0020).

    This is a [keeper_runtime]-owned boundary DTO. The queue is a low-level
    data module and must not depend on the [board] domain library, so the
    keeper layer converts to/from [Board_dispatch.board_signal] at the
    enqueue and drain boundaries. The board post id is not duplicated here:
    it is the enclosing [stimulus.post_id]. *)

type stimulus_payload =
  | Board_signal of board_stimulus
  | Board_attention of board_attention
      (** A Board signal admitted by the configured relevance judge. The
          opaque [candidate_id] is the producer-owned durable event identity;
          queue deduplication never derives it from post text or metadata. *)
  | Bootstrap
  | Fusion_completed of fusion_completion
  | Schedule_due of scheduled_wake
      (** A scheduled automation request has reached its due time and directly
          targeted this keeper. The Scheduler owns timing/approval; the keeper
          receives only a typed wake with the operator-authored message. *)
  | Connector_attention of connector_attention
      (** RFC-connector-ambient-attention-wake: an ambient connector message
          recorded as [Keeper_external_attention]. Carries the [event_id]
          pointer into that durable store (not the content), so the wake reads
          content on the turn path and there is no payload duplication.
          Edge-triggered: dequeued once, re-armed only by a new ambient
          message. Dormant until [handle_ambient] enqueues it (P3). *)
  | Hitl_resolved of hitl_resolution
  | Ask_answered of ask_answered
      (** A question this keeper asked a human has been answered. Carries the
          [ask_id] pointer only; the answer text stays in [Keeper_ask_store]
          and the woken keeper reads it there. Without this wake the answer is
          written where only a screen reads it and the asking keeper has to
          remember to go and look — which is why no keeper had asked. *)
      (** A nonblocking HITL approval this keeper enqueued was resolved. Wakes
          the keeper so it re-evaluates immediately instead of waiting for an
          unrelated stimulus, no-progress recovery, or the 30-minute approval
          janitor. Blocking approvals resume their resolver directly and do not
          emit this duplicate wake. Mirrors [Fusion_completed]. *)
  | Completion_authority_rejected of completion_authority_rejection
      (** A system completion authority rejected this Keeper's submitted
          evidence. The event is delivered to the producer Keeper as typed
          follow-up context; the authority itself is not a Keeper. *)
  | Task_cancelled of task_cancellation
      (** Another Keeper cancelled a Task this Keeper authored. Cancellation is
          the one terminal outcome with no Board projection — completion posts a
          verdict, submission posts a request, but a cancellation left only a
          backlog field and an activity row. The cancelling Keeper's reason is
          carried here because it is the author's only account of why the work
          it asked for stopped. *)
  | Workspace_message of workspace_message
      (** A committed workspace message named this Keeper. The transcript row
          the delivery boundary appends is the content SSOT; this payload
          carries the durable workspace request identity so the message is
          also an entry in the linear per-Keeper drain — ordered against every
          other stimulus, deduplicated by request identity, and durable across
          a restart. *)
  | Delegate_completed of delegate_completion
      (** A turn one Keeper asked another to run has ended, and this carries
          the answer back to the asker. [masc_keeper_delegate] returns an id
          and nothing else, so before this payload the answer reached the
          asker only if it went back and read the id — measured over
          2026-08-17..24, no Keeper ever did (4 delegations, 0 status reads,
          10 cancels). Mirrors [Fusion_completed] and [Hitl_resolved]: an
          async completion the waiting Keeper has to be told about. *)
  | Composition_completed of composition_completion
      (** An async composition this Keeper submitted has finished. The tool
          returns a request id and does not wait, so before this payload the
          result reached the submitter only if it remembered to read that id
          back. Measured over 2026-08-18..26: 22 submissions, 12 reads, and a
          result sat unread for a median of 21.9s against a median 2.7ms of
          work -- one waited 47 minutes. Mirrors [Delegate_completed]. *)
(** Closed set of stimulus kinds. Replaces the prior [payload : string] +
    [classify] JSON-prefix round-trip: producers hold the typed value and
    consumers match it exhaustively, so an unrecognised stimulus is
    unrepresentable rather than silently downgraded to [Unsupported].
    [Fusion_completed] (RFC-0266) wakes the calling keeper when an async
    [masc_fusion] deliberation finishes so the result arrives as actionable
    turn input rather than being discovered passively. *)

and board_attention = {
  candidate_id : string;
  signal : board_stimulus;
}

and fusion_completion = {
  run_id : string;
  terminal : fusion_terminal;
  board_post_id : string;
  channel : Keeper_continuation_channel.t;
}

and fusion_terminal =
  | Fusion_succeeded of string
  | Fusion_failed of string
  | Fusion_cancelled
(** Typed terminal receipt for [Fusion_completed]. Structural cancellation is
    distinct from an ordinary deliberation failure, so consumers never infer
    it from an error string. The string payloads are the synthesized answer or
    explicit failure detail. [board_post_id] correlates to the sink's board
    evidence post ("" when none was created). *)

and delegate_completion = {
  dc_operation_id : string;
  dc_keeper : string;
  dc_terminal : delegate_terminal;
}
(** Payload for [Delegate_completed]. [dc_operation_id] is the id
    [masc_keeper_delegate] returned, so the asker matches the answer to its
    own request; [dc_keeper] is the Keeper that ran the turn. *)

and delegate_terminal =
  | Delegate_replied of string
  | Delegate_no_reply
  | Delegate_failed of string
(** Typed outcome for [Delegate_completed]. [Delegate_replied] carries the
    visible reply. [Delegate_no_reply] means the turn ended with no text to
    hand back — it either did its work through a tool that posted elsewhere,
    or said nothing; the two are not told apart because neither gives the
    asker something to read. [Delegate_failed] carries the failure detail. *)

and composition_completion = {
  cc_request_id : string;
  cc_tool : string;
  cc_terminal : composition_terminal;
}
(** Payload for [Composition_completed]. [cc_request_id] is the id the async
    composition tool returned, so the submitter matches the result to its own
    request and reads it with [keeper_composition_status]; [cc_tool] names
    which composition finished, because a Keeper can have several in flight. *)

and composition_terminal =
  | Composition_succeeded
  | Composition_failed of string
  | Composition_cancelled of string
(** Typed outcome for [Composition_completed]. [Composition_succeeded] carries
    no body: the result is already durable in the async request record and
    [keeper_composition_status] already reads it, so copying it here would put
    the same bytes in two durable stores that can then disagree — the choice
    [Connector_attention] makes about ambient message content. Failure and
    cancellation carry their detail, which exists nowhere else the woken
    Keeper can act on. *)

and hitl_resolution_decision =
  | Hitl_approved
  | Hitl_rejected of string

and hitl_resolution = {
  approval_id : string;
  decision : hitl_resolution_decision;
  channel : Keeper_continuation_channel.t;
}
(** Payload for [Ask_answered]: [ask_id] is the correlation identity, and
    [channel] is where the question was asked so a woken keeper answers into
    that conversation rather than its own state. Only the pointer travels; the
    answer lives in [Keeper_ask_store]. *)
and ask_answered = {
  ask_id : string;
  channel : Keeper_continuation_channel.t;
}

(** Payload for [Hitl_resolved]: [approval_id] is the correlation identity.
    The durable Gate journal remains the SSOT for an approved exact request.
    Rejection rationale and edited input are resolution output, not
    authorization state, and travel durably in the event so the wake is
    actionable. Only [Hitl_approved] can produce a one-shot grant. *)

and connector_attention = {
  event_id : string;
  channel : Keeper_continuation_channel.t;
}
(** RFC-connector-ambient-attention-wake payload for [Connector_attention]:
    [event_id] is the pointer into [Keeper_external_attention] for the ambient
    message; content/surface are read from that store on the turn path. *)

and scheduled_wake = {
  occurrence_id : string;
  schedule_instance_id : string;
  schedule_id : string;
  due_at : float;
  payload_digest : string;
  title : string option;
  message : string;
  result_delivery : Keeper_continuation_channel.t option;
}
(** Payload for [Schedule_due]: the schedule consumer has already validated the
    request and enqueued this wake for the named keeper. The schedule instance
    identity prevents a terminal receipt from a pruned request from matching a
    later request that reuses the same public [schedule_id]. [payload_digest]
    preserves a stable audit correlation to the schedule payload without
    duplicating its raw JSON envelope in the keeper queue. [result_delivery]
    is [None] for an explicit no-delivery policy and [Some channel] only when
    schedule creation captured an authorized originating continuation.
    [occurrence_id] is the exact schedule occurrence correlation key. *)

and completion_authority_rejection = {
  car_task_id : string;
  car_verification_id : string;
  car_reason : string;
  car_authority : Masc_domain.completion_authority;
}
(** Typed follow-up context for a rejected completion-evidence submission,
    including the authenticated system-LLM or HITL authority provenance. *)

and task_cancellation = {
  tc_task_id : string;
  tc_cancelled_by : string;
  tc_reason : string option;
}
(** Payload for [Task_cancelled]. [tc_reason] is [None] when the canceller gave
    none; it is not defaulted to a placeholder, so the author can tell "no
    reason was given" from "the reason was empty text". *)

and workspace_message = {
  wmsg_request_id : string;
  wmsg_from : string;
}
(** Payload for [Workspace_message]. [wmsg_request_id] is the workspace message's
    durable request id, which is also the [external_message_id] of the chat
    row the delivery boundary committed — one identity, two stores, so the
    content is never duplicated here. [wmsg_from] is the authoring agent, kept
    because a drained stimulus has to name its sender without a second read. *)

val workspace_message_post_id : workspace_message -> post_id
(** Dedup/correlation id for [Workspace_message]:
    ["workspace-message:<request_id>"]. Redelivery of the same committed
    workspace message collapses onto the entry already queued. *)

val fusion_completion_post_id : fusion_completion -> post_id
(** Canonical dedup/correlation id for [Fusion_completed], always
    ["fusion-run:<run_id>"]. Board projection availability is not event
    identity. *)

val delegate_completion_post_id : delegate_completion -> post_id
(** Dedup/correlation id for [Delegate_completed]:
    ["keeper-delegate:<operation_id>"]. One delegation answers once, so the
    operation id alone is a complete key. *)

val composition_completion_post_id : composition_completion -> post_id
(** Dedup/correlation id for [Composition_completed]:
    ["keeper-composition:<request_id>"]. One async request settles once, so
    the request id alone is a complete key. *)

val ask_answered_post_id : ask_answered -> post_id
(** Dedup/correlation id for [Ask_answered]: ["keeper-ask:<ask_id>"]. One
    answer per question, so the ask id alone is a complete key. *)

val hitl_resolution_post_id : hitl_resolution -> post_id
(** Dedup/correlation id for [Hitl_resolved]: ["hitl-approval:<approval_id>"].
    De-dups repeat resolve wakes for the same approval within the dedup
    window. *)

val completion_authority_rejection_post_id :
  completion_authority_rejection -> post_id

val task_cancellation_post_id : task_cancellation -> post_id
(** Dedup/correlation id for [Task_cancelled]: ["task-cancelled:<task_id>"].
    Cancellation is terminal, so the task id alone is a complete key. *)

val hitl_resolution_decision_to_string : hitl_resolution_decision -> string
(** Stable wire/log label for a HITL resolution wake decision. *)

type stimulus = {
  post_id : post_id;
  urgency : urgency;
  arrived_at : float;  (** Unix timestamp, monotonic clock preferred. *)
  payload : stimulus_payload;
}

type t
(** Persistent FIFO queue of stimuli. *)

val empty : t

val length : t -> int
val is_empty : t -> bool

val enqueue : t -> stimulus -> t
(** [enqueue q s] appends [s] to the back of [q] in O(1). Always succeeds. *)

val stimulus_identity_equal : stimulus -> stimulus -> bool
(** [true] when two stimuli describe the same durable event. The comparison
    intentionally ignores [arrived_at], so restart/bootstrap re-enqueues do
    not create an unbounded backlog of otherwise identical stimuli. For a
    [Fusion_completed] event, [channel] is also excluded: the first committed
    row owns recipient authority, and a replay sources the channel from the
    durable delivery obligation, so an [Unrouted] first commit followed by a
    recovered-channel replay must not conflict. Result, run, and Board
    evidence must still match exactly. *)

val to_list : t -> stimulus list
(** Return the FIFO contents. *)

val dequeue : t -> (stimulus * t) option
(** [dequeue q] removes and returns the front of [q], or [None] when
    empty. The Policy Layer must call this at the start of every
    [emit] turn to honour the KeeperEventQueue [TurnDequeue] action. *)

val remove_by_post_id : post_id -> t -> stimulus list * t
(** Remove all stimuli whose [post_id] matches the argument, returning the
    removed stimuli in FIFO order plus the remaining queue. *)

val contains : t -> stimulus -> bool
(** [contains q s] is [true] when some stimulus already in [q] compares equal
    to [s] under {!stimulus_identity_equal}. Queue order is unchanged. *)

val uniq_stimuli : stimulus list -> stimulus list
(** Remove duplicate stimuli by {!stimulus_identity_equal} while preserving the
    first occurrence order. *)

val sort_by_urgency : t -> t
(** Stable sort: [Immediate] < [Normal] < [Low]. Two stimuli of the
    same urgency keep insertion order, so urgency reordering does
    not invalidate per-bucket FIFO. *)

val low_to_normal_aging_threshold_sec : float
(** How long a [Low] stimulus waits before {!effective_urgency} promotes it
    to [Normal]. A reasoned default (matches common recurring-schedule
    cadence in this fleet), not a measured distribution. *)

(** [effective_urgency ~now s] is [s.urgency], except a [Low] stimulus
    promotes to [Normal] once it has waited at least
    {!low_to_normal_aging_threshold_sec}. Never promotes into [Immediate]:
    that tier stays a producer-declared contract (#31597). *)

val effective_urgency_rank : now:float -> stimulus -> int
(** [urgency_rank (effective_urgency ~now s)]. *)

val summary : t -> string
(** Short human-readable description for log lines. *)

val payload_kind_label : stimulus_payload -> string
(** Stable short label for logs/metrics. *)

val urgency_to_string : urgency -> string
val urgency_of_string : string -> (urgency, string) result

val is_board_signal : stimulus_payload -> bool
(** [true] iff the payload is a [Board_signal]. *)

val connector_attention_channel :
  stimulus_payload -> Keeper_continuation_channel.t option
(** [Some channel] iff the payload is [Connector_attention], carrying its
    routed channel. [None] for every other payload kind (RFC-0377 batch
    intake). *)

val drain_board_all : t -> stimulus list * t
(** [drain_board_all q] separates every board-signal stimulus from the
    rest of the queue, regardless of arrival time (RFC-0334 W2: the turn
    is the batching unit, not an arrival window — identity dedup at
    enqueue already bounds the batch).  Board signals are urgency-sorted
    (explicit mentions enqueue as [Immediate], so they surface first);
    non-board stimuli remain in the returned queue in their original
    order. *)

val stimulus_to_yojson : stimulus -> Yojson.Safe.t
(** Stable JSON representation used by MASC-owned durable queue snapshots. *)

val stimulus_of_yojson : Yojson.Safe.t -> (stimulus, string) result
(** Parse a stimulus written by [stimulus_to_yojson]. *)

val queue_to_yojson : t -> Yojson.Safe.t
(** Stable JSON representation of the queue in FIFO order. *)

val queue_of_yojson : Yojson.Safe.t -> (t, string) result
(** Parse a queue written by [queue_to_yojson]. *)

val continuation_channel_of_payload :
  stimulus_payload -> Keeper_continuation_channel.t option
(** Reply route named by a continuation-bearing stimulus. [None] for every
    other payload and for a scheduled wake without a persisted result
    destination. *)
