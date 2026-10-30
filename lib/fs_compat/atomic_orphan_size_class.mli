(** Closed sum for the [size_class] label on atomic-orphan cleanup metrics. *)

type t =
  | Empty
  | With_data

val to_label : t -> string
