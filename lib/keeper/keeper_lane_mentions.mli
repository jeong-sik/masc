(** Keeper_lane_mentions — keeper identity adapter for explicit mention tokens
    (RFC-0232 §3.3).

    The exact ["@name"] token parser lives in {!Board_types.Mention_id} so
    keeper chat and board rows share one protocol syntax.  This module applies
    keeper-specific canonicalization on top of those raw token ids:
    writers parse a user line once at append, persist the resulting
    {!Keeper_identity.Keeper_id.t} list on the line, and observation filters on
    the persisted ids only.

    Tokenization contract: a line mentions [x] when some
    whitespace-separated token equals ["@" ^ x] after trimming non-word edge
    characters.  Token equality, not
    substring — ["@alicex"] and ["email@alice.com"] do not mention
    ["alice"].  On top of the legacy contract, extracted names are
    minted through {!Keeper_identity.Keeper_id.of_string}, so
    keeper-shaped forms (["@keeper-alice"]) canonicalize to the same
    id as the bare name. *)

val mention_ids_of_content : string -> Keeper_identity.Keeper_id.t list
(** Every ["@name"] token of the content, edge-trimmed, minted to a
    canonical id, deduplicated.  [[]] when the line mentions nobody. *)

val target_ids_of : string list -> Keeper_identity.Keeper_id.t list
(** Mint a keeper's mention-target names (e.g.
    [message_feed_targets meta]) into comparable ids. *)

val ids_match
  :  target_ids:Keeper_identity.Keeper_id.t list
  -> Keeper_identity.Keeper_id.t list
  -> bool
(** [ids_match ~target_ids mentions] — does any persisted mention hit a
    target?  The read-side replacement for the deleted
    [line_mentions ~targets content]. *)
