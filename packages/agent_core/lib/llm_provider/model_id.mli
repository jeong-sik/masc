(** Exact model identity selected for a provider call.

    This type is deliberately opaque.  It preserves the complete catalog or
    caller-supplied identifier and never classifies a model by prefix, family,
    provider, or endpoint. *)

type t

val of_string : string -> (t, string) result
val to_string : t -> string
val equal : t -> t -> bool
val compare : t -> t -> int
val hash : t -> int
val pp : Format.formatter -> t -> unit
