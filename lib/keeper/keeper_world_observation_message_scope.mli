(** Message-scope helpers for keeper world observation. *)

open Keeper_types

val scope_message_feed_enabled : keeper_meta -> bool
val message_feed_targets : keeper_meta -> string list
val self_identity_tokens : keeper_meta -> string list
val is_self_author : self_tokens:string list -> string -> bool
val is_keeper_authored_message : string -> bool

val collect_message_scope
  :  config:Coord.config
  -> meta:keeper_meta
  -> (string * string) list * (string * string) list * (string * int) list

val apply_message_cursor_updates
  :  keeper_meta
  -> (string * int) list
  -> keeper_meta
