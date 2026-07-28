open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

module StringSet : Set.S with type elt = string

type history_migration_stats =
  { moved_lines : int
  ; dropped_lines : int
  ; kept_lines : int
  ; malformed_lines : int
  }




val has_world_state_signature : string -> bool

type history_line_action =
  | Keep_main
  | Move_internal
  | Drop_line





val migrate_session_history_logs : session_dir:string -> history_migration_stats


val persist_message : ?source:string -> session_context -> Agent_sdk.Types.message -> unit
