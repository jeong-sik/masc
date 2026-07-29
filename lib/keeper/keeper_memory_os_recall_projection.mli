(** Typed projection over the persisted Memory OS stores. *)

type t =
  | Facts_and_episodes
  | Facts_only

val to_string : t -> string
val of_string : string -> t option
val all : t list
val valid_strings : string list
