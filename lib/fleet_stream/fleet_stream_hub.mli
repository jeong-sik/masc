(** Turns what each fleet scan found into the events of RFC-0477.

    The server tells the hub the outcome of every scan. The hub keeps the
    current state, numbers each event, and hands it to every subscriber. A scan
    that finds what the last one found makes no event, so a subscriber hears
    about the fleet changing and about nothing else.

    A subscriber is a function. It is called with the hub's lock held, so every
    subscriber sees the events in one order and the [Snapshot] it starts with
    is followed by the next event without a gap. That makes two demands on it:
    it must return without waiting (put the event in a bounded queue, and
    disconnect its own client when the queue is full), and it must not call the
    hub, which would wait for the lock it is running under. *)

type t

val create : on_subscriber_error:(exn -> unit) -> t
(** [on_subscriber_error] receives what a subscriber raised. A subscriber that
    raises is removed, because it can no longer be sure to see every event. It
    is called after the hub's lock is released. *)

val observe : t -> measured_at:float -> Fleet_stream.fleet -> unit
(** A scan finished at [measured_at] and read this fleet.

    - The first reading makes the state and sends [Snapshot] to every
      subscriber that was waiting for one.
    - A reading equal to the current one, while the scans are working, makes no
      event.
    - A different reading makes [Changed].
    - Any reading after [note_degraded] makes [Changed], equal or not, because
      the subscribers need to hear that the scans work again. *)

val note_degraded : t -> since:float -> Fleet_stream.degraded_reason -> unit
(** The scan failed or ran out of time. The first failure after a reading makes
    [Degraded]; the failures after it make nothing, so [since] stays the time
    the outage began. Before the first reading there is nothing to degrade and
    this does nothing. *)

val subscribe : t -> on_event:(Fleet_stream.event -> unit) -> unit -> unit
(** [subscribe t ~on_event] registers [on_event] and returns the function that
    removes it. If the hub has a reading, [on_event] receives its [Snapshot]
    before this returns and before any later event. If it has none, [on_event]
    receives [Snapshot] when the first reading arrives. *)

val current : t -> Fleet_stream.event option
(** The [Snapshot] a subscriber that connected now would start with. *)
