(** Shell operation vocabulary for the structured Grep surface. *)

type t =
  | Pwd
  | Ls
  | Cat
  | Rg
  | Git_status
  | Find
  | Head
  | Tail
  | Wc
  | Tree
  | Git_log
  | Git_diff

val to_string : t -> string
val all : t list
val valid_strings : string list
