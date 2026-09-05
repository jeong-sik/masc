open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

type history_line_action =
  | Keep_main
  | Move_internal
  | Drop_line

val persist_message : ?source:string -> session_context -> Agent_core.Types.message -> unit
