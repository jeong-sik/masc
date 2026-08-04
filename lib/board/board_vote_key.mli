(** Canonical identity for one Board vote. *)

open Board_types

type target_kind =
  | Post
  | Comment

type t

val post : post_id:Post_id.t -> voter:Agent_id.t -> t
val comment : comment_id:Comment_id.t -> voter:Agent_id.t -> t
val of_string : string -> t option
val to_string : t -> string
val target_kind : t -> target_kind
val target_id : t -> string
val voter : t -> Agent_id.t
