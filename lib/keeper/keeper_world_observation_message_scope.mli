(** Message-scope helpers for keeper world observation. *)

open Keeper_meta_contract
open Keeper_types_profile

val message_feed_targets : keeper_meta -> string list
val self_identity_tokens : keeper_meta -> string list
val is_self_author : self_tokens:string list -> string -> bool
val is_keeper_authored_message : string -> bool

(** [line_mentions ~targets content] is true when some whitespace token of
    [content] equals ["@" ^ target] for a target, after trimming surrounding
    punctuation. Token equality (not substring) so ["@dreamerx"] and
    ["email@dreamer.com"] do not match ["@dreamer"]. *)
val line_mentions : targets:string list -> string -> bool

(** [pending_mentions_of_messages ~targets messages] returns the [(speaker,
    content)] of every user line that mentions a target and arrives after the
    keeper's own last line. Pure (no I/O) so the watermark logic is testable
    directly; this is the core of {!collect_message_scope}. *)
val pending_mentions_of_messages
  :  targets:string list
  -> Keeper_chat_store.chat_message list
  -> (string * string) list

val collect_message_scope
  :  config:Workspace.config
  -> meta:keeper_meta
  -> (string * string) list * (string * string) list
