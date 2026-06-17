(** Lock-free atomic update helpers. *)

(** [update r f] atomically replaces the contents of [r] with [f (Atomic.get r)],
    retrying with a fresh read if a concurrent writer changed [r] between the read
    and the compare-and-set. *)
val update : 'a Atomic.t -> ('a -> 'a) -> unit
