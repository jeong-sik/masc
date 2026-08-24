type t =
  | Ok
  | Warming
  | Snapshot_not_ready
  | Degraded
  | Stale
  | Warning
  | Unavailable
  | Unknown
  | Blocked
  | Error
  | Timeout

val of_string_opt : string -> t option
(** [None] when the word is not in this vocabulary. Use this wherever the
    difference between an explicit ["unknown"] and a word nobody declared
    changes what happens. *)

val of_string : string -> t
val to_string : t -> string
val equal : t -> t -> bool
val pp : Format.formatter -> t -> unit
val rank : t -> int
val rank_string : string -> int
val max : t -> t -> t
val max_string : string -> string -> string
val requires_operator_action : t -> bool
