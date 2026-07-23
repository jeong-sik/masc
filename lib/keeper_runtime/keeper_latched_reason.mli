(** Typed SSOT for a durable Keeper lifecycle latch.

    Ordinary failure observations never inhabit this type. Structural
    transcript corruption is a reset-required lifecycle latch because replaying
    the same checkpoint is unsafe. Retired or unknown latches are rejected
    explicitly. *)

type t =
  | Operator_paused of { operator_actor : operator_actor }
  | Dead_tombstone
  | Transcript_corruption_reset_required

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
val operator_actor_to_wire : operator_actor -> string

module Stable : sig
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end
