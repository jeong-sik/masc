(** Keeper_lane_mentions — boundary mention parser for keeper chat lanes
    (RFC-0232 §3.3).

    The legacy [line_mentions] tokenizer ran at {e read} time inside the
    world-observation scan, re-deriving mention semantics from
    [chat_message.content] on every observation.  This module is that
    tokenizer relocated to the {e write} boundary: writers parse a user
    line once at append, persist the resulting {!Keeper_identity.Keeper_id.t}
    list on the line, and observation filters on the persisted ids only.

    Tokenization contract (unchanged from the legacy tokenizer): a line
    mentions [x] when some whitespace-separated token equals ["@" ^ x]
    after trimming non-word edge characters.  Token equality, not
    substring — ["@alicex"] and ["email@alice.com"] do not mention
    ["alice"].  On top of the legacy contract, extracted names are
    minted through {!Keeper_identity.Keeper_id.of_string}, so
    keeper-shaped forms (["@keeper-alice"]) canonicalize to the same
    id as the bare name. *)

val mention_ids_of_content : string -> Keeper_identity.Keeper_id.t list
(** Every ["@name"] token of the content, edge-trimmed, minted to a
    canonical id, deduplicated.  [[]] when the line mentions nobody. *)

type explicit_address =
  | No_explicit_address
  | Targets of Keeper_identity.Keeper_id.t list
  | Broadcast_all
  | Unsupported_broadcast of string list
(** Closed write-boundary interpretation of address tokens. [@@all] is the
    only Keeper-wide broadcast selector. Other [@@name] forms belong to the
    generic workspace agent-type router, whose type catalog is not a Keeper
    routing authority; they are retained as an explicit error instead of
    being downgraded to ambient content. *)

val explicit_address_of_content : string -> explicit_address
(** Parse the exact whitespace-token contract once. Broadcast takes
    precedence over direct targets, matching the existing workspace mention
    grammar. Unsupported broadcast selectors fail closed at the caller. *)

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
