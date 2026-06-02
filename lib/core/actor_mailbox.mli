(** Actor mailbox + loop driver for the actor model introduced in
    RFC-0059 Phase 2 (PR-5).

    Single-Domain only — PR-6 wraps these in a [Domain_pool] for
    parallel dispatch.  In a single Domain the loop is cooperative:
    [Eio.Stream.take] yields to peer fibers when the inbox is empty,
    and bounded inbox capacity provides backpressure to the producer
    when the consumer falls behind. *)

type 'msg t = 'msg Actor_types.t

val default_capacity : int
(** Default inbox capacity passed to {!Eio.Stream.create} when
    [?capacity] is omitted from {!create}.  Currently [64] — wide
    enough that a 10×/sec producer / 1×/sec consumer can absorb a
    six-second hiccup before [send] starts blocking, narrow enough
    that a stalled consumer does not silently buffer minutes of
    work. *)

val create : ?capacity:int -> string -> 'msg t
(** [create ~capacity name] allocates a fresh actor handle with a
    bounded inbox.  Raises [Invalid_argument] if [capacity < 1] —
    [Eio.Stream.create 0] yields rendez-vous semantics that this
    module deliberately does not expose. *)

val send : 'msg t -> 'msg -> unit
(** [send t msg] enqueues [msg] in the inbox.  Blocks the calling
    fiber when the inbox is full, propagating backpressure.  A
    non-blocking variant ([try_send]) is deferred — it requires
    tracking capacity on the actor record because [Eio.Stream] does
    not expose its bound after construction.  Add it when the first
    actor needs saturation-as-signal rather than backpressure. *)

val length : 'msg t -> int
(** Current inbox depth.  Snapshot only — the value can change before
    the caller acts on it.  Suitable for metrics, not for control
    flow. *)

val stop : 'msg t -> unit
(** Set the actor's stop signal.  The next iteration of {!run} that
    reaches the [stop_signal] check exits without taking another
    message.  In-flight handler invocations complete first.  This
    does {b not} wake a fiber blocked on [Eio.Stream.take] — to
    unblock a quiescent inbox the caller must also send a sentinel
    message that the handler routes to a [Stop] outcome. *)

val run :
  'msg t ->
  init:'state ->
  handle:('state -> 'msg -> 'state * Actor_types.handler_outcome) ->
  unit
(** [run t ~init ~handle] runs the actor loop in the {b current}
    fiber, threading [state] through successive messages.

    The handler returns a tuple of [(new_state, outcome)]; the loop
    follows [outcome]:
    - {!Actor_types.Continue}: recurse with [new_state].
    - {!Actor_types.Stop}: exit cleanly.

    The loop also exits when {!stop} has set [stop_signal] and the
    next iteration observes it (between message takes), or when the
    surrounding switch is cancelled and propagates
    [Eio.Cancel.Cancelled] up through [Eio.Stream.take]. *)
