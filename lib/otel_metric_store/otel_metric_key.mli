(** Stable metric-key encoding for metric name plus label pairs. *)

type label = string * string

val labels_key : label list -> string
val metric_key : string -> label list -> string
