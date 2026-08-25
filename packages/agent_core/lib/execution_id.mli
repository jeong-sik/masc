(** Internal constructors for opaque execution identifiers. *)

module type S = sig
  type t

  val fresh : unit -> (t, string) result
  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
  val show : t -> string
end

module Make (Prefix : sig
    val value : string
  end) : S

module Correlation : S
