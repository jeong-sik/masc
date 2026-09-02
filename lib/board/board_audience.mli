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
    persistence. A target candidate {!Agent_id.of_string} rejects is read as
    prose, not as a failed address, so it neither becomes a target nor rejects
    the post.

    An unaddressed [Public] or [Internal] post is [Discoverable]. An
    unaddressed [Unlisted] post is [Thread_participants]: it is not in any
    keeper's feed, so no attention judgment is spent on it, and a keeper
    reaches it by explicit address or by joining its thread. *)

val audience_for_comment : content:string -> (audience, board_error) result
(** An unaddressed comment belongs to [Thread_participants]. *)

val audience_for_reaction : audience
(** Reactions are structural thread activity and carry no textual address. *)

val audience_for_vote : audience
(** Votes are structural thread activity too; the keeper router selects the
    voted-on author from the signal payload. *)

val audience_label : audience -> string
