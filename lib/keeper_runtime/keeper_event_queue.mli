(** Event Layer queue for the keeper heartbeat loop.

    Models the contract verified in
    [specs/keeper-state-machine/KeeperEventQueue.tla]: enqueue is a
    side-effect-free Event Layer operation, the Policy Layer drains
    pending stimuli once it gets a turn, and dedup/urgency are
    bookkeeping concerns that never delay an [enqueue].

    This module is data only. The enqueue side is wired:
    [keeper_keepalive_signal.ml] calls [Keeper_registry_event_queue.enqueue]
    before the wakeup flag flips (RFC-0020 Rule 1). On the dequeue side,
    [keeper_heartbeat_loop.ml] drains the board-signal batch within the
    debounce window via [Keeper_registry_event_queue.drain_board] (a CAS loop
    over [drain_board_window]) and falls back to a single non-board
    [dequeue_event] when that batch is empty — either path pins the
    [Conservation] invariant. [run_smart_heartbeat_gate] then snapshots
    the queue and forces [Emit] when it is non-empty (pinning
    [QueueNeverStarvedBySkip] — the queue is read before any [Skip]
    takes effect, though that read currently lives in the gate rather
    than inside [Keeper_heartbeat_smart.should_emit] itself). *)

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

type board_stimulus = {
  kind : board_stimulus_kind;
  author : string;
  title : string;
  content : string;
  mention_ids : string list;
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
  | Bootstrap
  | No_progress_recovery
  | Fusion_completed of fusion_completion
  | Bg_completed of bg_job_completion
  | Schedule_signal of schedule_signal
      (** A schedule runner signal for a keeper-owned schedule. This carries the
          durable schedule signal identity and schedule id, not the payload
          body, so the keeper turn can re-read current schedule state instead
          of acting on a duplicated snapshot. *)
  | Connector_attention of connector_attention
      (** RFC-connector-ambient-attention-wake: an ambient connector message
          recorded as [Keeper_external_attention]. Carries the [event_id]
          pointer into that durable store (not the content), so the wake reads
          content on the turn path and there is no payload duplication.
          Edge-triggered: dequeued once, re-armed only by a new ambient
          message. The Discord ambient producer enqueues this when the
          registry flag enables ambient connector wakes. *)
  | Hitl_resolved of hitl_resolution
      (** A HITL approval this keeper enqueued — and skipped cycles on via
          [has_pending_for_keeper -> Skip Approval_pending] — was resolved.
          Wakes the keeper so it re-evaluates immediately instead of stalling
          until an unrelated stimulus, no-progress recovery, or the 30-minute
          approval janitor. Mirrors [Fusion_completed]/[Bg_completed]. *)
(** Closed set of stimulus kinds. Replaces the prior [payload : string] +
    [classify] JSON-prefix round-trip: producers hold the typed value and
    consumers match it exhaustively, so an unrecognised stimulus is
    unrepresentable rather than silently downgraded to [Unsupported].
    [Fusion_completed] (RFC-0266) wakes the calling keeper when an async
    [masc_fusion] deliberation finishes so the result arrives as actionable
    turn input rather than being discovered passively. *)

and fusion_completion = {
  run_id : string;
  ok : bool;
  resolved_answer : string;
  board_post_id : string;
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

and schedule_signal_kind =
  | Schedule_due_candidate
  | Schedule_due_blocked_approval

and schedule_signal = {
  schedule_signal_id : string;
  schedule_signal_kind : schedule_signal_kind;
  schedule_id : string;
  due_at : float;
  payload_digest : string;
}
(** Payload for [Schedule_signal]: the runner noticed a due keeper-owned
    schedule or a due schedule blocked on approval. [schedule_signal_id] is the
    id from [Schedule_runner.wake_signal]; [payload_digest] lets the keeper
    correlate with the schedule ledger without embedding payload content. *)

and hitl_resolution_decision =
  | Hitl_approved
  | Hitl_rejected
  | Hitl_edited

and hitl_resolution = {
  approval_id : string;
  decision : hitl_resolution_decision;
}
(** Payload for [Hitl_resolved]: [approval_id] correlates to the resolved
    pending-approval queue entry; [decision] is the resolved label
    ("approve" | "reject" | ...), carried for observability. The keeper
    re-evaluates from its own state once the approval leaves the queue, so the
    decision is not itself control flow. *)

and connector_attention = { event_id : string }
(** RFC-connector-ambient-attention-wake payload for [Connector_attention]:
    [event_id] is the pointer into [Keeper_external_attention] for the ambient
    message; content/surface are read from that store on the turn path. *)

val fusion_completion_post_id : fusion_completion -> post_id
(** Dedup/correlation id for [Fusion_completed]. Uses [board_post_id] when the
    sink created a board evidence post, otherwise falls back to
    ["fusion-run:<run_id>"]. *)

val bg_job_completion_post_id : bg_job_completion -> post_id
(** RFC-0290 dedup/correlation id for [Bg_completed]. Uses [bg_board_post_id]
    when the producer set it, otherwise falls back to ["bg-run:<run_id>"]. *)

val hitl_resolution_post_id : hitl_resolution -> post_id
(** Dedup/correlation id for [Hitl_resolved]: ["hitl-approval:<approval_id>"].
    De-dups repeat resolve wakes for the same approval within the dedup
    window. *)

val schedule_signal_post_id : schedule_signal -> post_id
(** Dedup/correlation id for [Schedule_signal]:
    ["schedule-signal:<schedule_signal_id>"]. *)

val schedule_signal_kind_to_string : schedule_signal_kind -> string
(** Stable wire/log label for a schedule runner signal kind. *)

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
(** Stable short label for logs/metrics: ["board_signal"], ["bootstrap"],
    ["no_progress_recovery"], ["fusion_completed"], or ["bg_completed"]. *)

val is_board_signal : stimulus_payload -> bool
(** [true] iff the payload is a [Board_signal]. *)

val drain_board_window : ?window_sec:float -> t -> stimulus list * t
(** [drain_board_window q] separates board-signal stimuli that arrived
    within [window_sec] seconds (default [2.0]) of now from the rest of
    the queue.  Board signals are urgency-sorted; non-board stimuli and
    board signals outside the window remain in the returned queue in
    their original order. *)

val stimulus_to_yojson : stimulus -> Yojson.Safe.t
(** Stable JSON representation used by MASC-owned durable queue snapshots. *)

val stimulus_of_yojson : Yojson.Safe.t -> (stimulus, string) result
(** Parse a stimulus written by [stimulus_to_yojson]. *)

val queue_to_yojson : t -> Yojson.Safe.t
(** Stable JSON representation of the queue in FIFO order. *)

val queue_of_yojson : Yojson.Safe.t -> (t, string) result
(** Parse a queue written by [queue_to_yojson]. *)
