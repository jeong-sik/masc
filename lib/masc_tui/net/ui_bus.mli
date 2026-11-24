(** Bounded coalescing event bus bridging [Io]/[Worker] producers to the single
    [Ui] consumer domain.

    - Keyed snapshot updates overwrite any unread older snapshot for the same
      key (latest-wins, zero unbounded growth, zero blocking).
    - Ordered stream chunks/logs append into a bounded ring (default cap 512).
      On extreme burst overflow, the oldest unread entry is evicted and an
      exact {!Stream_gap} count is accumulated and emitted ahead of the
      surviving tail — zero IO-reader stalls and zero SSE disconnects.
    - Wake coalescing latched under the microsecond-short internal queue mutex
      ensures [on_wake] fires outside the lock at most once per pending burst
      without a cross-domain lost-wakeup race. *)

val default_stream_capacity : int
(** [512]. *)

type ('snap_key, 'snap, 'ev) item =
  | Snapshot of 'snap_key * 'snap
  | Stream_event of 'ev
  | Stream_gap of int

type stats = {
  queued_snapshots : int;
  queued_stream_events : int;
  pending_gap : int;
  total_coalesced_snapshots : int;
  total_dropped_stream_events : int;
}

type ('snap_key, 'snap, 'ev) t

val create :
  ?stream_capacity:int ->
  key_equal:('snap_key -> 'snap_key -> bool) ->
  key_hash:('snap_key -> int) ->
  ?on_wake:(unit -> unit) ->
  unit ->
  ('snap_key, 'snap, 'ev) t
(** Create a bus with bounded stream ring [stream_capacity] (clamped to
    [>= 1], defaulting to {!default_stream_capacity}). *)

val publish_snapshot :
  ('snap_key, 'snap, 'ev) t -> key:'snap_key -> 'snap -> unit
(** Publish a latest-wins keyed snapshot. Never blocks. *)

val publish_stream : ('snap_key, 'snap, 'ev) t -> 'ev -> unit
(** Append an ordered stream event to the bounded ring. On overflow, evicts the
    oldest unread item and increments the pending {!Stream_gap} counter. Never
    blocks. *)

val drain : ('snap_key, 'snap, 'ev) t -> ('snap_key, 'snap, 'ev) item list
(** Atomically drain all pending snapshots, any accumulated {!Stream_gap}, and
    all queued stream events in FIFO order, re-arming the atomic wake hook. *)

val drain_up_to :
  max_items:int -> ('snap_key, 'snap, 'ev) t -> ('snap_key, 'snap, 'ev) item list
(** Drain at most [max_items] items (for bounded per-frame UI drain budgets).
    Snapshots are drained ahead of stream items; [Stream_gap] counts as 1 item. *)

val is_empty : ('snap_key, 'snap, 'ev) t -> bool
val stats : ('snap_key, 'snap, 'ev) t -> stats
