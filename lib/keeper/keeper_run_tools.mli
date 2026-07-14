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
type hook_accumulator =
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

(** Immutable snapshot of hook outputs after OAS execution completes. *)
type hook_outputs =
  { out_meta : Keeper_meta_contract.keeper_meta
  ; out_tool_calls : tool_call_detail list
  ; out_tool_surface : tool_surface_metrics
  ; out_requested_tool_names : string list
  ; out_receipt_completion_contract_result :
      Keeper_execution_receipt.completion_contract_result
  ; out_receipt_actionable_signal :
      Keeper_contract_classifier.actionable_signal option
  }

val freeze : hook_accumulator -> hook_outputs

(** Agent setup produced by Step 7.

    Hook mutations flow through {!acc}, receipt refs are kept for
    facade post-processing writes, and [agent_ref] is created locally
    at the OAS call site. *)
type agent_setup =
  { tools : Agent_sdk.Tool.t list
  ; cleanup : unit -> unit
  ; hooks : Agent_sdk.Hooks.hooks
  ; model_input_projection :
      Agent_sdk.Types.message list -> Agent_sdk.Types.message list
  ; acc : hook_accumulator
  ; all_tool_names : string list
  ; receipt_turn_count_ref : int option ref
  ; receipt_model_used_ref : string option ref
  ; receipt_stop_reason_ref : Runtime_agent.stop_reason option ref
  ; receipt_runtime_observation_ref : Runtime_observation.runtime_observation option ref
  ; receipt_response_text_present_ref : bool ref
  }

val prepare_agent_setup
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> turn_ctx_cell:Keeper_tool_call_log.turn_ctx_cell
  -> ctx_work:working_context
  -> session:Keeper_types.session_context
  -> base_system_prompt:string
  -> turn_system_prompt:string
  -> user_message:string
  -> dynamic_context:string
  -> history_messages:Agent_sdk.Types.message list
  -> prompt_metrics:Keeper_agent_prompt_metrics.prompt_metrics
  -> shared_context:Agent_sdk.Context.t
  -> context_injector:Agent_sdk.Hooks.context_injector
  -> start_turn_count:int
  -> generation:int
  -> runtime_id:string
  -> is_retry:bool
  -> config_root:string
  -> runtime_config_path:string option
  -> trajectory_acc:Trajectory.accumulator option
  -> ?runtime_manifest_context:Keeper_runtime_manifest.turn_context
  -> ?runtime_manifest_append:(Keeper_runtime_manifest.t -> unit)
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> ?hitl_resolution:Keeper_event_queue.hitl_resolution
  -> unit
  -> (agent_setup, Agent_sdk.Error.sdk_error) result
