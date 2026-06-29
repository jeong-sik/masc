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

val of_string : string -> t
val to_string : t -> string
val equal : t -> t -> bool
val pp : Format.formatter -> t -> unit
val rank : t -> int
val rank_string : string -> int
val max : t -> t -> t
val max_string : string -> string -> string
val requires_operator_action : t -> bool
val requires_operator_action_string : string -> bool
