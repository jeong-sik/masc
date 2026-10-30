(** The shim's monotonic clock.

    Two readings subtract to the interval that elapsed. [Unix.gettimeofday]
    readings do not: they measure the wall clock, so their difference also
    measures any correction it took in between — an NTP step, a VM resume,
    the first sync after boot.

    The shim's supervisor decides three intervals with this: when to kill the
    payload, how long to drain its pipes after the reap, and how long to wait
    before SIGKILL. A forward step used to kill a running command and report
    a timeout, with the drain cut short so its output came back truncated; a
    backward step withheld the deadline and the shim sat. *)

val elapsed_seconds : unit -> float
(** Seconds from an unspecified origin. Only differences mean anything — this
    is not a wall time and must not be reported as one. *)
