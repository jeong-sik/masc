(** Lamport Clock - Lock-free logical timestamps for causal ordering *)

type t

val create : unit -> t
val tick : t -> int
val recv : t -> remote_time:int -> int
val current : t -> int
val reset : t -> unit
val compare_timestamps : int -> int -> int
val happened_before : int -> int -> bool
