(** Hook accumulator + outputs for OAS Agent.run hook callbacks,
    extracted from keeper_run_tools.ml.

    OAS hooks (before_turn, on_tool_executed) cannot return values, so
    they write into a single mutable {!hook_accumulator} during
    Agent.run execution.  After execution completes, {!freeze} produces
    an immutable {!hook_outputs} snapshot. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_agent_tool_surface
open Keeper_agent_result

type hook_accumulator =
  { mutable meta : Keeper_meta_contract.keeper_meta
  ; mutable tool_calls : tool_call_detail list
  ; mutable current_turn : int
  ; mutable discovered : Keeper_discovered_tools.t
  ; mutable tool_overlay : Agent_sdk.Tool_op.t
  ; mutable tool_surface : tool_surface_metrics
  ; mutable requested_tool_names : string list
  ; mutable receipt_completion_contract_result :
      Keeper_execution_receipt.completion_contract_result
  }

type hook_outputs =
  { out_meta : Keeper_meta_contract.keeper_meta
  ; out_tool_calls : tool_call_detail list
  ; out_discovered : Keeper_discovered_tools.t
  ; out_tool_overlay : Agent_sdk.Tool_op.t
  ; out_tool_surface : tool_surface_metrics
  ; out_requested_tool_names : string list
  ; out_receipt_completion_contract_result :
      Keeper_execution_receipt.completion_contract_result
  }

let freeze (acc : hook_accumulator) : hook_outputs =
  { out_meta = acc.meta
  ; out_tool_calls = acc.tool_calls
  ; out_discovered = acc.discovered
  ; out_tool_overlay = acc.tool_overlay
  ; out_tool_surface = acc.tool_surface
  ; out_requested_tool_names = acc.requested_tool_names
  ; out_receipt_completion_contract_result = acc.receipt_completion_contract_result
  }
;;

let record_requested_tool_names (acc : hook_accumulator) requested =
  acc.requested_tool_names <- requested
;;
