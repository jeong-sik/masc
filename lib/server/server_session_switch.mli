(** The switch a server session runs under, failed rather than returned from.

    Eio's [Switch.run] joins ordinary fibers on the way out of a body that
    returned a value, and cancels them on the way out of one that raised. A
    server session starts background lanes -- [start_post_ready_owner_lanes]
    and what the transport itself forks -- and a lane parked on a wake has
    nothing left to end it once the session is over. Returning from the switch
    would wait for that lane forever; failing it cancels the lane instead.

    [run body] runs [body sw] and then ends the switch by failing it. An
    exception [body] raises propagates, and the switch fails the same way. *)

val run : (Eio.Switch.t -> unit) -> unit
