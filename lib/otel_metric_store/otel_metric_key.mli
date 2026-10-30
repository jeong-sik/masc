(** Stable metric key encoding for the in-memory OTel metric store. *)

type label = string * string

val metric_key : string -> label list -> string
