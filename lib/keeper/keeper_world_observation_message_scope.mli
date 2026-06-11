(** Message-scope helpers for keeper world observation. *)

open Keeper_meta_contract
open Keeper_types_profile

val message_feed_targets : keeper_meta -> string list
val self_identity_tokens : keeper_meta -> string list
val is_self_author : self_tokens:string list -> string -> bool
val is_keeper_authored_message : string -> bool

val collect_message_scope
  :  config:Workspace.config
  -> meta:keeper_meta
  -> (string * string) list * (string * string) list
