(* keeper_run_tools — Step 7 of run_turn: agent setup, tools, progressive
   disclosure, hooks assembly, context reducer.

   Extracted from keeper_agent_run.ml. *)

open Keeper_types
open Keeper_agent_tool_surface
open Keeper_agent_result
open Keeper_agent_error
open Keeper_agent_prompt_metrics

module Tool_search = Keeper_run_tools_search

(** Mutable accumulator for OAS hook callbacks.

    OAS hooks (before_turn, on_tool_executed) cannot return values, so
    they write into this single mutable record during Agent.run execution.
    After execution completes, {!freeze} produces an immutable snapshot. *)
type hook_accumulator = Keeper_run_tools_hook_accumulator.hook_accumulator =
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

type hook_outputs = Keeper_run_tools_hook_accumulator.hook_outputs =
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

let freeze = Keeper_run_tools_hook_accumulator.freeze
let merge_requested_tool_names_seen = Keeper_run_tools_hook_accumulator.merge_requested_tool_names_seen
let record_requested_tool_names = Keeper_run_tools_hook_accumulator.record_requested_tool_names

let task_scope_tool_names = Keeper_run_tools_task_scope.task_scope_tool_names
let json_string_opt = Keeper_run_tools_task_scope.json_string_opt
let task_id_scope_of_tool_input = Keeper_run_tools_task_scope.task_id_scope_of_tool_input
let task_id_scope_of_claim_output = Keeper_run_tools_task_scope.task_id_scope_of_claim_output
let task_id_scope_of_tool_call = Keeper_run_tools_task_scope.task_id_scope_of_tool_call

type tool_search_hit_partition = Tool_search.tool_search_hit_partition =
  { visible_core_hits : (string * float) list
  ; discoverable_hits : (string * float) list
  ; filtered_by_policy : int
  }

let partition_tool_search_hits = Tool_search.partition_tool_search_hits
let truncate_tool_surface_names = Tool_search.truncate_tool_surface_names

(** Agent setup produced by Step 7.

    Hook mutations flow through {!acc}, receipt refs are kept for
    facade post-processing writes, and [agent_ref] is created locally
    at the OAS call site. *)
type agent_setup = Keeper_run_tools_hooks.agent_setup =
  { tools : Agent_sdk.Tool.t list
  ; cleanup : unit -> unit
  ; hooks : Agent_sdk.Hooks.hooks
  ; reducer : Agent_sdk.Context_reducer.t
  ; memory : Agent_sdk.Memory.t
  ; acc : hook_accumulator
  ; initial_tool_surface : computed_tool_surface
  ; initial_tool_surface_blocker : Agent_sdk.Error.sdk_error option ref
  ; all_tool_names : string list
  ; tool_usage_before : (string * int) list
  ; receipt_turn_count_ref : int option ref
  ; receipt_model_used_ref : string option ref
  ; receipt_stop_reason_ref : Cascade_runner.stop_reason option ref
  ; receipt_cascade_observation_ref : Cascade_observation.cascade_observation option ref
  ; receipt_response_text_present_ref : bool ref
  ; reported_tool_names_ref : string list ref
  ; observed_tool_names_ref : string list ref
  ; canonical_tool_names_ref : string list ref
  ; unexpected_tool_names_ref : string list ref
  ; actual_keeper_tool_names_ref : string list ref
  }


let prepare_agent_setup = Keeper_run_tools_setup.prepare_agent_setup
