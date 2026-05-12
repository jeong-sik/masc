(** Event Layer queue for the keeper heartbeat loop.

    Models the contract verified in
    [specs/keeper-state-machine/KeeperEventQueue.tla]: enqueue is a
    side-effect-free Event Layer operation, the Policy Layer drains
    pending stimuli once it gets a turn, and dedup/urgency are
    bookkeeping concerns that never delay an [enqueue].

    This module is data only. The enqueue side is wired:
    [keeper_keepalive_signal.ml] calls [Keeper_registry.enqueue_event]
    before the wakeup flag flips (RFC-0020 Rule 1). On the dequeue side,
    [keeper_heartbeat_loop.ml] drains the board-signal batch within the
    debounce window via [Keeper_registry.drain_board_events] (a CAS loop
    over [drain_board_window]) and falls back to a single non-board
    [dequeue_event] when that batch is empty — either path pins the
    [Conservation] invariant. [run_smart_heartbeat_gate] then snapshots
    the queue and forces [Emit] when it is non-empty (pinning
    [QueueNeverStarvedBySkip] — the queue is read before any [Skip]
    takes effect, though that read currently lives in the gate rather
    than inside [Heartbeat_smart.should_emit] itself). *)

type urgency =
  | Immediate  (** operator commands and other latency-critical signals *)
  | Normal     (** board posts, mentions *)
  | Low        (** background polling, telemetry-driven nudges *)

type post_id = string
(** Identifier used by [dedup_by_post_id] to collapse repeat events.

    The runtime uses the originating board post id, the mention
    target id, or the operator directive token. The queue does
    not interpret the value beyond equality. *)

type stimulus = {
  post_id : post_id;
  urgency : urgency;
  arrived_at : float;  (** Unix timestamp, monotonic clock preferred. *)
  payload : string;
}

type t
(** Persistent FIFO queue of stimuli. *)

val empty : t

val length : t -> int
val is_empty : t -> bool

val enqueue : t -> stimulus -> t
(** [enqueue q s] appends [s] to the back of [q]. Always succeeds. *)

val dequeue : t -> (stimulus * t) option
(** [dequeue q] removes and returns the front of [q], or [None] when
    empty. The Policy Layer must call this at the start of every
    [emit] turn to honour the KeeperEventQueue [TurnDequeue] action. *)

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

type stimulus_class =
  | Board_signal   (** JSON payload with {"source":"board_signal", ...} *)
  | Bootstrap      (** Plain string "Keeper bootstrap signal" *)
  | Alive_but_stuck_recovery
      (** JSON payload with {"source":"alive_but_stuck_recovery", ...} *)
  | Unsupported of string  (** Unrecognized: payload prefix (max 40 chars) for audit *)

val classify : stimulus -> stimulus_class
(** [classify s] discriminates the stimulus by inspecting its payload.
    No Yojson dependency — uses lightweight prefix matching so the Event
    Layer data module stays self-contained. *)

val drain_board_window : ?window_sec:float -> t -> stimulus list * t
(** [drain_board_window q] separates board-signal stimuli that arrived
    within [window_sec] seconds (default [2.0]) of now from the rest of
    the queue.  Board signals are urgency-sorted; non-board stimuli and
    board signals outside the window remain in the returned queue in
    their original order. *)
