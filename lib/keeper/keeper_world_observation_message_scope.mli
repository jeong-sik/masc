(** Message-scope helpers for keeper world observation. *)

open Keeper_meta_contract
open Keeper_types_profile

val message_feed_targets : keeper_meta -> string list
val self_identity_tokens : keeper_meta -> string list
val is_self_author : self_tokens:string list -> string -> bool
val is_keeper_authored_message : string -> bool

(** A lane line parsed into a typed signal at the observation boundary
    (RFC-0230 §3.1). [Scope_message] is reserved for P2; P1's
    {!classify_lane_line} emits only [Direct_mention], [Self_authored], and
    [Ambient]. *)
type lane_signal =
  | Direct_mention of { speaker : string; at : float }
  | Scope_message of { speaker : string; at : float }
  | Self_authored
  | Ambient

(** [classify_lane_line ~self_tokens ~mention_targets ~speaker ~text ~at]
    parses one lane line into a {!lane_signal}. A line authored by the keeper
    itself (per [self_tokens]) is [Self_authored]; otherwise an "@<target>"
    match against [mention_targets] yields [Direct_mention], and anything else
    is [Ambient]. Pure: no [keeper_meta], no I/O. *)
val classify_lane_line
  :  self_tokens:string list
  -> mention_targets:string list
  -> speaker:string
  -> text:string
  -> at:float
  -> lane_signal

val collect_message_scope
  :  config:Workspace.config
  -> meta:keeper_meta
  -> (string * string) list * (string * string) list * (string * int) list

val apply_message_cursor_updates
  :  keeper_meta
  -> (string * int) list
  -> keeper_meta
