(** Event Layer queue for the keeper heartbeat loop.

    Models the contract verified in
    [specs/keeper-state-machine/KeeperEventQueue.tla]: enqueue is a
    side-effect-free Event Layer operation, the Policy Layer drains
    pending stimuli once it gets a turn, and dedup/urgency are
    bookkeeping concerns that never delay an [enqueue].

    This module is data only. The enqueue side is wired:
    [keeper_keepalive_signal.ml] calls [Keeper_registry_event_queue.enqueue]
    before the wakeup flag flips (RFC-0020 Rule 1). On the dequeue side,
    [keeper_heartbeat_loop.ml] leases every queued board signal at turn
    start via [Keeper_registry_event_queue.claim_board_result] (a CAS loop
    over [drain_board_all], RFC-0334 W2) and falls back to one typed non-board
    lease when that batch is empty — either path pins the
    [Conservation] invariant. The per-Keeper wakeup atomic cuts the configured
    heartbeat sleep, and no policy layer may suppress the following cycle. *)

type urgency =
  | Immediate  (** operator commands and other latency-critical signals *)
  | Normal     (** board posts, mentions *)
  | Low        (** background polling, telemetry-driven nudges *)

type post_id = string
(** Identifier used by [dedup_by_post_id] to collapse repeat events.

    The runtime uses the originating board post id, the mention
    target id, or the operator directive token. The queue does
    not interpret the value beyond equality. *)

type board_stimulus_kind =
  | Post_created
  | Comment_added
  | Reaction_changed of board_reaction_change

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
  | Bg_completed of bg_job_completion
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
      (** A nonblocking HITL approval this keeper enqueued was resolved. Wakes
          the keeper so it re-evaluates immediately instead of waiting for an
          unrelated stimulus, no-progress recovery, or the 30-minute approval
          janitor. Blocking approvals resume their resolver directly and do not
          emit this duplicate wake. Mirrors [Fusion_completed]/[Bg_completed]. *)
  | Failure_judgment of failure_judgment
      (** RFC-0313 deterministic failure class was rejected/blocked and should
          produce an LLM-boundary verdict prompt on the keeper lane. *)
  | Goal_assigned of goal_assignment
      (** A goal was newly added to this keeper's [active_goal_ids]. *)
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
  ok : bool;
  resolved_answer : string;
  board_post_id : string;
  channel : Keeper_continuation_channel.t;
}
(** RFC-0266 payload for [Fusion_completed]: [ok] distinguishes a synthesized
    judge result from denied/sink_failed/aborted; [resolved_answer] carries the
    answer (or a failure label when [ok = false]); [board_post_id] correlates to
    the sink's board evidence post ("" when none was created). *)

and bg_job_completion = {
  bg_run_id : string;
  bg_kind : bg_job_kind;
  bg_outcome : bg_job_outcome;
  bg_board_post_id : string;
}
(** RFC-0290 payload for [Bg_completed]: mirrors [fusion_completion]. [bg_kind]
    is a closed sum so a new job kind forces exhaustive handling; [bg_outcome]
    carries the result payload ([Bg_ok]) or a failure label ([Bg_failed]);
    [bg_board_post_id] correlates to an optional board evidence post ("" if
    none). *)

and bg_job_kind = Subprocess
(** RFC-0290: background job kinds. Closed sum (v1 = [Subprocess]); a new kind
    forces every match to add an arm rather than defaulting. *)

and bg_job_outcome =
  | Bg_ok of string  (** result payload *)
  | Bg_failed of string  (** failure label *)

and hitl_resolution_decision =
  | Hitl_approved
  | Hitl_rejected of string
  | Hitl_edited of Yojson.Safe.t

and hitl_resolution = {
  approval_id : string;
  decision : hitl_resolution_decision;
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
  schedule_id : string;
  due_at : float;
  payload_digest : string;
  title : string option;
  message : string;
}
(** Payload for [Schedule_due]: the schedule consumer has already validated the
    request and enqueued this wake for the named keeper. [payload_digest]
    preserves a stable audit correlation to the schedule payload without
    duplicating its raw JSON envelope in the keeper queue. *)

and failure_judgment = {
  fj_runtime_id : string;
  fj_judgment : Keeper_runtime_failure_route.judgment_class;
  fj_provenance : Keeper_runtime_failure_route.judgment_provenance;
  fj_detail : string;
}
(** Payload for [Failure_judgment]. [fj_runtime_id] is the opaque failed
    binding identity, [fj_judgment] is the routing class, and
    [fj_provenance] retains the typed execution boundary (including the OAS
    idle-loop count). [fj_detail] is display/prompt evidence and is never used
    for routing. *)

and goal_assignment = {
  ga_goal_id : string;
  ga_goal_title : string;
  ga_assigned_by : string;
}
(** Payload for [Goal_assigned]. *)


val fusion_completion_post_id : fusion_completion -> post_id
(** Dedup/correlation id for [Fusion_completed]. Uses [board_post_id] when the
    sink created a board evidence post, otherwise falls back to
    ["fusion-run:<run_id>"]. *)

val bg_job_completion_post_id : bg_job_completion -> post_id
(** RFC-0290 dedup/correlation id for [Bg_completed]. Uses [bg_board_post_id]
    when the producer set it, otherwise falls back to ["bg-run:<run_id>"]. *)

val schedule_due_post_id : scheduled_wake -> post_id
(** Dedup/correlation id for [Schedule_due]: ["schedule-due:<schedule_id>"]. *)

val hitl_resolution_post_id : hitl_resolution -> post_id
(** Dedup/correlation id for [Hitl_resolved]: ["hitl-approval:<approval_id>"].
    De-dups repeat resolve wakes for the same approval within the dedup
    window. *)

val failure_judgment_post_id : failure_judgment -> post_id

val goal_assignment_post_id : goal_assignment -> post_id

val hitl_resolution_decision_to_string : hitl_resolution_decision -> string
(** Stable wire/log label for a HITL resolution wake decision. *)

val bg_job_kind_to_string : bg_job_kind -> string
(** RFC-0290: stable label for a background job kind, for logs and correlation
    (["subprocess"]). *)

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
    not create an unbounded backlog of otherwise identical stimuli. *)

val to_list : t -> stimulus list
(** Return the FIFO contents. *)

val dequeue : t -> (stimulus * t) option
(** [dequeue q] removes and returns the front of [q], or [None] when
    empty. The Policy Layer must call this at the start of every
    [emit] turn to honour the KeeperEventQueue [TurnDequeue] action. *)

val prepend_list : stimulus list -> t -> t
(** [prepend_list stimuli q] puts [stimuli] back at the front of [q] while
    preserving [stimuli]'s order. Used when a keepalive cycle crashes after
    draining stimuli but before completing the turn, so restart/retry keeps an
    at-least-once replay boundary. *)

val remove_by_post_id : post_id -> t -> stimulus list * t
(** Remove all stimuli whose [post_id] matches the argument, returning the
    removed stimuli in FIFO order plus the remaining queue. *)

val uniq_stimuli : stimulus list -> stimulus list
(** Remove duplicate stimuli by {!stimulus_identity_equal} while preserving the
    first occurrence order. *)

val dedup_by_identity : t -> t
(** Collapse duplicate durable-event identities in a queue. *)

val remove_by_post_id_pair : post_id -> t -> t -> stimulus list * t * t
(** Remove matching stimuli from two queues and return the de-duplicated
    removed stimuli plus both remaining queues. *)

val dedup_by_post_id : ?window_seconds:float -> t -> t
(** Drops later duplicates of the same [post_id] when their
    [arrived_at] differs by less than [window_seconds] (default
    [60.0]). FIFO order of survivors is preserved. *)

val sort_by_urgency : t -> t
(** Stable sort: [Immediate] < [Normal] < [Low]. Two stimuli of the
    same urgency keep insertion order, so urgency reordering does
    not invalidate per-bucket FIFO. *)

val summary : t -> string
(** Short human-readable description for log lines. *)

val payload_kind_label : stimulus_payload -> string
(** Stable short label for logs/metrics. *)

val urgency_to_string : urgency -> string
val urgency_of_string : string -> (urgency, string) result

val is_board_signal : stimulus_payload -> bool
(** [true] iff the payload is a [Board_signal]. *)

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
