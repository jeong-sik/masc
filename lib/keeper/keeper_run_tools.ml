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

(** Mutable accumulator for AGENT_CORE hook callbacks.

    AGENT_CORE hooks (before_turn, on_tool_executed) cannot return values, so
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
  ; mutable assistant_turn_texts : string list
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

(** Agent setup produced by Step 7.

    Hook mutations flow through {!acc}, receipt refs are kept for
    facade post-processing writes, and [agent_cell] is made here rather
    than at the AGENT_CORE call site because the turn's tools capture it. *)
type agent_setup = Keeper_run_tools_hooks.agent_setup =
  { tools : Agent_core.Tool.t list
  ; agent_core_tools : Agent_core.Tool.t list
  ; agent_cell : Agent_core.Agent.t option ref
  ; cleanup : unit -> unit
  ; terminal_effect_state : unit -> Keeper_tools_agent_core.terminal_effect_state
  ; user_message : string
  ; hooks : Agent_core.Hooks.hooks
  ; on_runtime_attempt : Keeper_turn_driver.runtime_attempt -> unit
  ; model_input_projection : Agent_core.Agent.model_input_projection
  ; stage_skill_delivery_on_wire :
      runtime_id:string -> agent_core_turn:int -> Agent_core.Types.message list -> unit
  ; observe_official_client_result_handoff :
      runtime_id:string ->
      invocation:Agent_core.Tool_contract.Invocation.t ->
      content:string ->
      unit
  ; observe_official_client_native_action :
      runtime_id:string -> official_turn:int ->
      identity:Runtime_native_tools.action_identity -> tool_name:string -> unit
  ; gate_replay_evidence : Keeper_gate_replay.model_evidence option
  ; acc : hook_accumulator
  ; all_tool_names : string list
  ; skill_projection_diagnostics : Keeper_skill_catalog.projection_diagnostic list
  ; final_agent_core_turn_ordinal_ref : int option ref
  ; receipt_turn_count_ref : int option ref
  ; receipt_model_used_ref : string option ref
  ; receipt_stop_reason_ref : Runtime_agent.stop_reason option ref
  ; receipt_runtime_observation_ref : Runtime_observation.runtime_observation option ref
  ; receipt_lane_attempt_index_ref : int ref
  ; receipt_response_text_present_ref : bool ref
  }

let prepare_agent_setup = Keeper_run_tools_setup.prepare_agent_setup
