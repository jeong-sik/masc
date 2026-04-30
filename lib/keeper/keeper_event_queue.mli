(** Event Layer queue for the keeper heartbeat loop.

    Models the contract verified in
    [specs/keeper-state-machine/KeeperEventQueue.tla]: enqueue is a
    side-effect-free Event Layer operation, dequeue happens once per
    Policy Layer turn, and dedup/urgency are bookkeeping concerns
    that never delay an [enqueue].

    This module is data only. Wiring into
    [keeper_keepalive_signal.wakeup_keeper] and
    [Heartbeat_smart.should_emit] lives in a follow-up patch so
    the queue can be exercised in isolation by tests first. *)

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
