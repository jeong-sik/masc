(** Where a [Process_eio] subprocess timeout fired. *)

type t =
  | Spawn
  | Command

val to_label : t -> string
(** Stable wire label for metrics and JSON payloads. *)
