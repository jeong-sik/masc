(** Exact, opaque provider model identifiers. Values retain their declared
    bytes; equality folds ASCII case without trimming, prefix matching or
    separator reconstruction. Api_name and Model_id remain distinct types. *)

module Equality_key : sig
  type t = private string
  val compare : t -> t -> int
  val equal : t -> t -> bool
end

module Api_name : sig
  type t
  val of_string : string -> (t, string) result
  val of_string_exn : string -> t
  val equal : t -> t -> bool
  val to_string : t -> string
end

module Model_id : sig
  type t
  val of_string : string -> (t, string) result
  (** Reject empty or padded identifiers; preserve all other producer bytes. *)
  val of_string_exn : string -> t
  val equal : t -> t -> bool
  val equality_key : t -> Equality_key.t
  val to_string : t -> string
end
