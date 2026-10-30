(** Typed SSOT for a durable Keeper lifecycle latch.

    Ordinary failure observations never inhabit this type: a past failure is
    evidence, not a scheduling gate. Retired or unknown latches are rejected
    explicitly. *)

type t = Operator_paused of { operator_actor : operator_actor }

and operator_actor =
  | Grpc_directive
  | Keeper_down

val to_wire : t -> string
val of_wire : string -> (t, string) result
val equal : t -> t -> bool
val hash : t -> int
val pp : Format.formatter -> t -> unit

val operator_actor_grpc_directive : operator_actor
val operator_actor_keeper_down : operator_actor
module Stable : sig
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end
