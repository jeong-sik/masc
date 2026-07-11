(** Process-lifetime switch shared by Keeper orchestration producers.

    This leaf owns the singleton so lifecycle workers do not depend back on
    [Keeper_supervisor], which itself consumes those workers. *)

let switch : Eio.Switch.t option Atomic.t = Atomic.make None
let set sw = Atomic.set switch (Some sw)
let get () = Atomic.get switch
