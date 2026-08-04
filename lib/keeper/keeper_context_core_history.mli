open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

module StringSet : Set.S with type elt = string

val normalize_system_context_prefix : string -> string

val has_world_state_signature : string -> bool

type history_line_action =
  | Keep_main
  | Move_internal
  | Drop_line

val classify_history_entry : source:string -> content:string -> history_line_action

val history_path_for_source : session_dir:string -> source:string option -> string

val persist_message : ?source:string -> session_context -> Agent_sdk.Types.message -> unit
