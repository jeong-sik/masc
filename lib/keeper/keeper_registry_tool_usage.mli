(** Keeper tool-usage map and persistence helpers. *)

open Keeper_types

val record
  :  tool_call_entry StringMap.t
  -> tool_name:string
  -> success:bool
  -> now:float
  -> tool_call_entry StringMap.t

val sorted : tool_call_entry StringMap.t -> (string * tool_call_entry) list
val save : base_path:string -> name:string -> flushed_at:float -> tool_call_entry StringMap.t -> unit
val load : base_path:string -> name:string -> (string * tool_call_entry) list
