(** Stable metric store keys. *)

type label = string * string

val labels_key : label list -> string
val metric_key : string -> label list -> string
