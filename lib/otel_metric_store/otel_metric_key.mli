(** Stable metric key encoding for the in-memory OTel metric store. *)

type label = string * string

val labels_key : label list -> string
val metric_key : string -> label list -> string
