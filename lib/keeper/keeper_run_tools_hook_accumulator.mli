(** Hook accumulator + outputs for OAS Agent.run hook callbacks.

    OAS hooks cannot return values, so they write into one mutable record
    during execution.  The facade freezes this into an immutable snapshot
    after the provider call returns. *)

open Keeper_types
open Keeper_agent_tool_surface
open Keeper_agent_result

type hook_accumulator =
  { mutable meta : Keeper_types.keeper_meta
  ; mutable tool_calls : tool_call_detail list
  ; mutable current_turn : int
  ; mutable completion_contract : Keeper_tool_disclosure.completion_contract
  ; mutable required_tool_use_seen : bool
  ; mutable keeper_surface_tool_used : bool
  ; mutable discovered : Keeper_discovered_tools.t
  ; mutable tool_overlay : Agent_sdk.Tool_op.t
  ; mutable tool_surface : tool_surface_metrics
  ; mutable requested_tool_names : string list
  ; mutable requested_tool_names_seen : string list
  ; mutable receipt_tool_contract_result :
      Keeper_execution_receipt.tool_contract_result
  ; mutable contract_violation_retries : int
  }

type hook_outputs =
  { out_meta : Keeper_types.keeper_meta
  ; out_tool_calls : tool_call_detail list
  ; out_completion_contract : Keeper_tool_disclosure.completion_contract
  ; out_required_tool_use_seen : bool
  ; out_keeper_surface_tool_used : bool
  ; out_discovered : Keeper_discovered_tools.t
  ; out_tool_overlay : Agent_sdk.Tool_op.t
  ; out_tool_surface : tool_surface_metrics
  ; out_requested_tool_names : string list
  ; out_requested_tool_names_seen : string list
  ; out_receipt_tool_contract_result :
      Keeper_execution_receipt.tool_contract_result
  ; out_contract_violation_retries : int
  }

val freeze : hook_accumulator -> hook_outputs

val merge_requested_tool_names_seen :
  seen:string list -> string list -> string list

val record_requested_tool_names : hook_accumulator -> string list -> unit
