(** Opaque monotonic identity for a durable Board-attention partition state.

    A generation advances exactly once for each legal state transition.
    Cursor-fenced confirmation reappends retain the same generation. *)

type t

val initial : t
val next : t -> (t, string) result
val equal : t -> t -> bool
val is_direct_successor : previous:t -> t -> bool
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result
