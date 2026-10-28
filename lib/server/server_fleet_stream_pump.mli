(** One client's side of the fleet stream (RFC-0477), without the socket.

    [run] subscribes to the fleet events, keeps what it hears in a bounded
    queue, and hands the client one SSE frame at a time through [send]. It
    ends when [send] reports that the client is gone, when the client let
    [max_queued_events] events pile up, or when one [send] takes longer than
    [stalled_after_s].

    The pile-up closes the connection and drops what was queued. The client
    rebuilds its state from the [Snapshot] it receives on reconnecting, and an
    event skipped in the middle would show up there as a gap in the revisions.

    The pile-up is acted on when the [send] in progress returns, and nothing is
    written after it. A [send] that waits for a client that is not reading
    cannot return, so it is bounded by [stalled_after_s]: the pump ends then,
    drops the queue and removes the subscription. What is held until then is
    the bounded queue and one frame. *)

type ending =
  | Client_gone  (** [send] returned [false]. *)
  | Fell_behind  (** An event arrived while [max_queued_events] were waiting. *)
  | Stalled  (** One [send] did not return within [stalled_after_s]. *)

val keepalive_frame : string
(** The SSE comment written when no event came for [ping_interval_s]. A reader
    that sees it knows a quiet fleet from a dead connection, and the SSE
    decoder yields no event for it. *)

val run :
  subscribe:(on_event:(Fleet_stream.event -> unit) -> unit -> unit) ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ping_interval_s:float ->
  stalled_after_s:float ->
  max_queued_events:int ->
  send:(string -> bool) ->
  ending
(** [run ~subscribe ~clock ~ping_interval_s ~stalled_after_s ~max_queued_events
    ~send] serves one client until it ends.

    - [subscribe ~on_event] registers [on_event] and returns the function that
      removes it, as {!Fleet_stream_hub.subscribe} does. The subscription is
      removed before [run] returns, and when it is cancelled or raises.
    - [send frame] writes one whole frame and returns once it reached the
      client, or [false] if it cannot. It may wait. While it waits the events
      queue up, which is how a client that stopped reading is noticed. It is
      cancelled when [stalled_after_s] passes without its return.
    - The interval counts from the last frame, so a stream that carries events
      writes no keepalive.
    - [stalled_after_s] is positive. It counts from the call of each [send],
      keepalives included. A [send] that returns as the time runs out has
      returned.
    - [max_queued_events] is at least 1. *)
