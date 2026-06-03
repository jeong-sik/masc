(** Hook accumulator + immutable outputs for OAS Agent.run callbacks. *)

type hook_accumulator =
  { mutable meta : Keeper_meta_contract.keeper_meta
  ; mutable tool_calls : Keeper_agent_result.tool_call_detail list
  ; mutable current_turn : int
  ; mutable keeper_surface_tool_used : bool
  ; mutable discovered : Keeper_discovered_tools.t
  ; mutable tool_overlay : Agent_sdk.Tool_op.t
  ; mutable tool_surface : Keeper_agent_tool_surface.tool_surface_metrics
  ; mutable requested_tool_names : string list
  }

type hook_outputs =
  { out_meta : Keeper_meta_contract.keeper_meta
  ; out_tool_calls : Keeper_agent_result.tool_call_detail list
  ; out_keeper_surface_tool_used : bool
  ; out_discovered : Keeper_discovered_tools.t
  ; out_tool_overlay : Agent_sdk.Tool_op.t
  ; out_tool_surface : Keeper_agent_tool_surface.tool_surface_metrics
  ; out_requested_tool_names : string list
  }

val freeze : hook_accumulator -> hook_outputs

val record_requested_tool_names :
  hook_accumulator -> string list -> unit
