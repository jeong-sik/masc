(** One client's side of an SSE stream fed by a producer (RFC-0493 §3.2),
    without the socket.

    [run] is the connection's one sending fiber: it takes events from a
    {!source} in order and writes each frame through [send], which waits for
    the client. Only that fiber waits for the client; a producer never does.
    The stream ends when [send] reports that the client is gone or stalled,
    when the source says to write no more, or when the stream says it is done
    ([Send_last], [Stop], [Finish]).

    Producers of the fleet, Keeper chat and MCP [subscriptions/listen] streams
    put events in a bounded {!Queue} and return at once. Its source stops once
    the client let the queue fill up. The pile-up ends the stream and drops
    what was queued. Each stream says how its client catches up after
    reconnecting: the fleet stream sends a [Snapshot] (RFC-0477), and the
    Keeper chat stream replays the journal after [since_seq] (RFC-0412). The
    MCP GET, AG-UI and presence streams take from their [Sse] queue instead,
    and their source stops when the connection is stopped.

    The pump asks the source whether to stop before each take and right
    before each [send]. Once it is told to stop, nothing more is written. A
    stop on another domain can come after that look, while the frames are
    handed to [send] or wait for the socket; that stop is acted on when the
    [send] returns. *)

type ending =
  | Client_gone  (** [send] answered [Closed]. *)
  | Source_stopped
  (** The source said to write no more. A {!Queue} says so once an event came
      while it was full. *)
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

type 'event source =
  { take : unit -> 'event
  (** Waits for the next event. The pump cancels a take that is still waiting
      when the ping interval ends, so a cancelled take must take nothing:
      nothing between removing an event and returning it may suspend. *)
  ; take_nonblocking : unit -> 'event option
  (** The next event if one is waiting, without waiting for one. *)
  ; stopped : unit -> bool
  (** [true] once nothing more is to be written. Any domain may make it
      [true]. *)
  }
(** Where [run] takes its events from. *)

val max_batch_bytes : int
(** A batch takes no more waiting frames once it holds this many bytes,
    64 KiB, so one [send] carries at most this plus one frame. A client that
    takes less than this within the response's stall bound has stopped
    reading, so the bound keeps its meaning for a batch. *)

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

  val source : 'event t -> 'event source
  (** Takes the pushed events in order. It stops once an event came while
      the queue was full. *)
end

val run :
  source:'event source ->
  step:('event -> step) ->
  idle:(unit -> idle) ->
  clock:_ Eio.Time.clock ->
  ping_interval_s:float ->
  send:(string -> Server_sse_response.outcome) ->
  ending
(** [run ~source ~step ~idle ~clock ~ping_interval_s ~send] serves one client
    until it ends.

    - The caller subscribes the producer before [run], and removes the
      subscription when the stream's switch ends. Frames the caller sends
      itself before [run] go out before every event of [source].
    - [idle ()] is asked when no event came for [ping_interval_s]. The
      interval counts from the last frame or skip, so a stream that carries
      events is not asked.
    - An event taken as the interval runs out is that event: it has left the
      source, and the idle answer is not used in its place.
    - The frames of the events already waiting when one is taken go out in
      the same [send], within {!max_batch_bytes}, so a burst waits for the
      client once per batch. A [Send_last] or [Stop] ends the batch and then
      the stream. Nothing is taken after the source says to stop, and a stop
      seen before a [send] ends the stream without it, even for the frames of
      events taken earlier. *)
