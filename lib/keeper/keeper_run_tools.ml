(* keeper_run_tools — Step 7 of run_turn: agent setup, tools, progressive
   disclosure, hooks assembly, context reducer.

   Extracted from keeper_agent_run.ml. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_agent_tool_surface
open Keeper_agent_result
open Keeper_agent_error
open Keeper_agent_prompt_metrics

(** Mutable accumulator for OAS hook callbacks.

    OAS hooks (before_turn, on_tool_executed) cannot return values, so
    they write into this single mutable record during Agent.run execution.
    After execution completes, {!freeze} produces an immutable snapshot. *)
type hook_accumulator = Keeper_run_tools_hook_accumulator.hook_accumulator =
  { mutable meta : Keeper_meta_contract.keeper_meta
  ; mutable tool_calls : tool_call_detail list
  ; mutable current_turn : int
  ; mutable tool_surface : tool_surface_metrics
  ; mutable requested_tool_names : string list
  ; mutable receipt_completion_contract_result :
      Keeper_execution_receipt.completion_contract_result
  ; mutable receipt_actionable_signal :
      Keeper_contract_classifier.actionable_signal option
  ; mutable prompt_blocks : Turn_record.prompt_block list
  ; mutable extra_system_context_digest : string option
  ; mutable extra_system_context_size : int option
  }

type hook_outputs = Keeper_run_tools_hook_accumulator.hook_outputs =
  { out_meta : Keeper_meta_contract.keeper_meta
  ; out_tool_calls : tool_call_detail list
  ; out_tool_surface : tool_surface_metrics
  ; out_requested_tool_names : string list
  ; out_receipt_completion_contract_result :
      Keeper_execution_receipt.completion_contract_result
  ; out_receipt_actionable_signal :
      Keeper_contract_classifier.actionable_signal option
  }

let freeze = Keeper_run_tools_hook_accumulator.freeze
let record_requested_tool_names = Keeper_run_tools_hook_accumulator.record_requested_tool_names

let task_scope_tool_names = Keeper_run_tools_task_scope.task_scope_tool_names
let task_id_scope_of_tool_input = Keeper_run_tools_task_scope.task_id_scope_of_tool_input
let task_id_scope_of_claim_output = Keeper_run_tools_task_scope.task_id_scope_of_claim_output
let task_id_scope_of_tool_call = Keeper_run_tools_task_scope.task_id_scope_of_tool_call

(** Agent setup produced by Step 7.

    Hook mutations flow through {!acc}, receipt refs are kept for
    facade post-processing writes, and [agent_ref] is created locally
    at the OAS call site. *)
type agent_setup = Keeper_run_tools_hooks.agent_setup =
  { tools : Agent_sdk.Tool.t list
  ; cleanup : unit -> unit
  ; hooks : Agent_sdk.Hooks.hooks
  ; reducer : Agent_sdk.Context_reducer.t
  ; acc : hook_accumulator
  ; all_tool_names : string list
  ; tool_context_estimate : Keeper_run_prompt.tool_schema_context_estimate
  ; receipt_turn_count_ref : int option ref
  ; receipt_model_used_ref : string option ref
  ; receipt_stop_reason_ref : Runtime_agent.stop_reason option ref
  ; receipt_runtime_observation_ref : Runtime_observation.runtime_observation option ref
  ; receipt_response_text_present_ref : bool ref
  }


let prepare_agent_setup = Keeper_run_tools_setup.prepare_agent_setup
