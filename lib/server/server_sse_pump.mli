(** One client's side of an SSE stream fed by a producer (RFC-0493 §3.2),
    without the socket.

    Producers put events in a bounded {!Queue} and return at once. [run] is
    the connection's one sending fiber: it takes the events in order and
    writes each frame through [send], which waits for the client. Only that
    fiber waits for the client; a producer never does. The stream ends when
    [send] reports that the client is gone or stalled, when the client let
    the queue fill up, or when the stream says it is done ([Send_last],
    [Stop], [Finish]).

    The pile-up closes the connection and drops what was queued. Each stream
    says how its client catches up after reconnecting: the fleet stream sends
    a [Snapshot] (RFC-0477), and the Keeper chat stream replays the journal
    after [since_seq] (RFC-0412). A pile-up is acted on when the [send] in
    progress returns, and nothing is written after it. *)

type ending =
  | Client_gone  (** [send] answered [Closed]. *)
  | Fell_behind  (** An event came while the queue was full. *)
  | Stalled  (** [send] answered [Stalled]. *)
  | Finished
  (** A [Send_last] frame was written, or [step] said [Stop], or [idle] said
      [Finish]. *)

type step =
  | Skip  (** Nothing is written for this event. *)
  | Send of string  (** The whole frame is written and the stream goes on. *)
  | Send_last of string  (** The whole frame is written and the stream ends. *)
  | Stop  (** Nothing is written and the stream ends. *)

type idle =
  | Keepalive  (** {!keepalive_frame} is written. *)
  | Quiet  (** Nothing is written; the next interval starts. *)
  | Finish  (** Nothing is written and the stream ends. *)

val keepalive_frame : string
(** The SSE comment written for [Keepalive]. A reader that sees it knows a
    quiet stream from a dead connection, and the SSE decoder yields no event
    for it. *)

module Queue : sig
  type 'event t

  val create : max_queued_events:int -> 'event t
  (** [max_queued_events] is at least 1. *)

  val push : 'event t -> 'event -> unit
  (** Puts an event in the queue, or marks the client behind when
      [max_queued_events] are waiting. Never waits. Any number of producers
      may push at once, from any domain, so a producer holding its own lock
      (the fleet hub does) can call it. *)
end

val run :
  queue:'event Queue.t ->
  step:('event -> step) ->
  idle:(unit -> idle) ->
  clock:_ Eio.Time.clock ->
  ping_interval_s:float ->
  send:(string -> Server_sse_response.outcome) ->
  ending
(** [run ~queue ~step ~idle ~clock ~ping_interval_s ~send] serves one client
    until it ends.

    - The caller subscribes the producer to [queue] before [run], and removes
      the subscription when the stream's switch ends. Frames the caller sends
      itself before [run] (a replay) go out before every queued event.
    - [idle ()] is asked when no event came for [ping_interval_s]. The
      interval counts from the last frame or skip, so a stream that carries
      events is not asked.
    - An event taken as the interval runs out is that event: it has left the
      queue, and the idle answer is not used in its place. *)
