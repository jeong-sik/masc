(** Canonical identity for one Board vote. *)

open Board_types

(** What a vote points at. [Board_types.reaction_target_type] draws the same
    line for reactions; folding the two into one type is #42987. *)
type target_kind =
  | Post
  | Comment

val target_kind_to_string : target_kind -> string
(** ["post"] or ["comment"]: the first segment of {!to_string}, and the
    karma ledger's [target_kind]. *)

type t

val post : post_id:Post_id.t -> voter:Agent_id.t -> t
val comment : comment_id:Comment_id.t -> voter:Agent_id.t -> t
val of_string : string -> t option
val to_string : t -> string
val target_kind : t -> target_kind
val target_id : t -> string
val voter : t -> Agent_id.t
