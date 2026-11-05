(** One client's side of an SSE stream fed by a producer (RFC-0493 §3.2),
    without the socket.

    [run] subscribes to the producer, keeps what it hears in a bounded queue,
    and hands the client one SSE frame at a time through [send]. Only the
    fiber that calls [run] waits for the client; the producer never does. The
    pump ends when [send] reports that the client is gone or stalled, or when
    the client let [max_queued_events] events pile up.

    The pile-up closes the connection and drops what was queued. Each stream
    says how its client catches up after reconnecting: the fleet stream sends
    a [Snapshot] (RFC-0477).

    The pile-up is acted on when the [send] in progress returns, and nothing is
    written after it. A [send] that waits for a client that is not reading is
    bounded by the response it writes to ({!Server_sse_response}), which
    answers [Stalled]. What is held until then is the bounded queue and one
    frame. *)

type ending =
  | Client_gone  (** [send] answered [Closed]. *)
  | Fell_behind  (** An event arrived while [max_queued_events] were waiting. *)
  | Stalled  (** [send] answered [Stalled]. *)

val keepalive_frame : string
(** The SSE comment written when no event came for [ping_interval_s]. A reader
    that sees it knows a quiet stream from a dead connection, and the SSE
    decoder yields no event for it. *)

val run :
  subscribe:(on_event:('event -> unit) -> unit -> unit) ->
  frame:('event -> string) ->
  clock:_ Eio.Time.clock ->
  ping_interval_s:float ->
  max_queued_events:int ->
  send:(string -> Server_sse_response.outcome) ->
  ending
(** [run ~subscribe ~frame ~clock ~ping_interval_s ~max_queued_events ~send]
    serves one client until it ends.

    - [subscribe ~on_event] registers [on_event] and returns the function that
      removes it, as {!Fleet_stream_hub.subscribe} does. [on_event] returns at
      once. The subscription is removed before [run] returns, and when it is
      cancelled or raises.
    - [frame event] is the whole SSE frame for [event].
    - [send frame] writes one whole frame and returns once it reached the
      client, the response closed, or the response's stall bound passed. While
      it waits the events queue up, which is how a client that stopped reading
      is noticed.
    - The interval counts from the last frame, so a stream that carries events
      writes no keepalive.
    - [max_queued_events] is at least 1. *)
