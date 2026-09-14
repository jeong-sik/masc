(** A deadline that keeps a finished result.

    [run clock seconds f] runs [f] and ends it as [Error `Timeout] when it
    has not finished after [seconds] on [clock]. Unlike
    [Eio.Time.with_timeout], which keeps whichever arm finished first, a
    finished [f] stands even when it finished in the same scheduler pass the
    deadline expired: a received response is never reported as one that did
    not arrive. An exception from [f] propagates, the timer cancelled.

    @stability Internal *)
val run : _ Eio.Time.clock -> float -> (unit -> 'a) -> ('a, [> `Timeout ]) result
