(** Exact write-boundary Board audience parser. *)

include module type of struct
  include Board_types
end

val direct_targets_of_text : string -> Agent_id.t list
(** Exact single-at target tokens, canonicalized and deduplicated. Broadcast
    and unsupported double-at selectors are not direct targets. *)

val audience_for_post
  :  visibility:visibility
  -> title:string
  -> content:string
  -> (audience, board_error) result
(** Parse the immutable audience of a new post. A [Direct] post requires exact
    targets; a targetless or broadcast Direct post is rejected before
    persistence. Malformed target syntax also fails closed. *)

val audience_for_comment : content:string -> (audience, board_error) result
(** An unaddressed comment belongs to [Thread_participants]. *)

val audience_for_reaction : audience
(** Reactions are structural thread activity and carry no textual address. *)

val audience_label : audience -> string
