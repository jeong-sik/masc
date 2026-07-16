(** Canonical identities carried by Keeper compaction operation events. *)

type id_error = Invalid_canonical_uuid

module Operation_id : sig
  type t
  val generate : unit -> t
  val of_string : string -> (t, id_error) result
  val to_string : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
end

module Attempt_id : sig
  type t
  val generate : unit -> t
  val of_string : string -> (t, id_error) result
  val to_string : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
end

module Cause : sig
  type t
  type error =
    | Empty
    | Noncanonical
  val of_string : string -> (t, error) result
  val to_string : t -> string
  val equal : t -> t -> bool
end
