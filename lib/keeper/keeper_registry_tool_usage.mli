(** Keeper tool-usage map and persistence helpers. *)

open Keeper_registry_types

val record
  :  Keeper_types.tool_call_entry StringMap.t
  -> tool_name:string
  -> success:bool
  -> now:float
  -> Keeper_types.tool_call_entry StringMap.t

val sorted
  :  Keeper_types.tool_call_entry StringMap.t
  -> (string * Keeper_types.tool_call_entry) list

val save
  :  base_path:string
  -> name:string
  -> flushed_at:float
  -> Keeper_types.tool_call_entry StringMap.t
  -> unit

val load : base_path:string -> name:string -> (string * Keeper_types.tool_call_entry) list
