(** Monotonic workspace and reconnect generation counter.

    Every outgoing HTTP request and SSE subscription is tagged with the active
    {!t}. Replies carrying an older epoch are rejected in a single guard before
    any domain store is updated. *)

type t

val initial : t
val next : t -> t
val to_int : t -> int
val of_int : int -> t option
(** Strict parser: returns [None] for negative integers. *)

val equal : t -> t -> bool
val compare : t -> t -> int

val is_current : current:t -> reply:t -> bool
(** [true] iff [reply] matches [current]. *)
