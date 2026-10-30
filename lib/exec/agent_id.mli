(** Opaque observability identity attached to process execution. *)

type t

val of_string : string -> t
val to_string : t -> string
