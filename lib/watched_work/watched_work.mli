(** Work raced against a watcher, where the work's own outcome stands.

    [Eio.Fiber.first] keeps whichever arm finished first and drops the
    other's result, and eio_posix runs expired timers before ready fds. So
    when the work's wake-up is queued behind the watcher's in the same
    scheduler pass -- the answer's last byte and the deadline arriving
    together -- an answer that had arrived was reported as the watcher's
    verdict: a timeout, a closed scope, an idle stream. [run] keeps the
    work's outcome whenever the work finished; the watcher's verdict is the
    result only when it has not. *)

val run : watcher:(unit -> 'a) -> (unit -> 'a) -> 'a
(** [run ~watcher work] runs both. The one still running when the other
    finishes is cancelled, as with [Eio.Fiber.first]; when both finished,
    [work]'s result is the result. An exception from either propagates. *)
