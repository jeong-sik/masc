(** Exact write-boundary Board audience parser. *)

include module type of struct
  include Board_types
end

val direct_targets_of_text : string -> Agent_id.t list
(** Exact single-at target tokens, canonicalized and deduplicated. Broadcast
    and unsupported double-at selectors are not direct targets. *)

val audience_for_post
  :  lookup:Recipient_lookup.t
  -> post_kind:post_kind
  -> visibility:visibility
  -> title:string
  -> content:string
  -> (audience * string list, board_error) result
(** Decide the immutable audience of a new post, and the names in its text
    that look like addresses but no Keeper declares ([unresolved], as the
    author wrote them, each once).

    A name after [@] is a target only when [lookup] declares it, and then the
    target is the Keeper it stands for. An undeclared name is prose: it is not
    a target and does not reject the post. When [lookup] cannot answer the
    post is refused with {!Recipient_lookup_failed} and nothing is written.

    A [System_post] reads no address from its text and never asks [lookup]:
    platform code decides whom it reaches, so its audience follows its
    visibility alone. A [Direct] post requires at least one declared target;
    a targetless or broadcast Direct post is rejected before persistence.

    An unaddressed [Public] or [Internal] post is [Discoverable]. An
    unaddressed [Unlisted] post is [Thread_participants]: it is not in any
    keeper's feed, so no attention judgment is spent on it, and a keeper
    reaches it by explicit address or by joining its thread. *)

val audience_for_comment
  :  lookup:Recipient_lookup.t
  -> content:string
  -> (audience * string list, board_error) result
(** As {!audience_for_post}, for a comment. An unaddressed comment belongs to
    [Thread_participants]. *)

val audience_for_reaction : audience
(** Reactions are structural thread activity and carry no textual address. *)

val audience_for_vote : audience
(** Votes are structural thread activity too; the keeper router selects the
    voted-on author from the signal payload. *)

val audience_label : audience -> string

val to_yojson : audience -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> audience option
(** Exact persisted audience shape; invalid or empty targets are rejected. *)
