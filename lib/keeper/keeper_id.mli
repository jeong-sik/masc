(** Type-safe identifiers for the Keeper domain.
    Implements "Parse, Don't Validate" by making IDs abstract or private. *)

module Keeper_name : sig
  type t = private string
  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
end

module Trace_id : sig
  type t = private string
  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
end

module Task_id : sig
  type t = private string
  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
end