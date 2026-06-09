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

(** [of_string s] is the variant whose [to_string] equals [s], or [None] for
    an unknown op. Inverse of [to_string]; use at the dispatch boundary to
    parse the raw op string into a variant before matching. *)
val of_string : string -> t option
