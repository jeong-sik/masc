(* keeper_run_tools — Step 7 of run_turn: agent setup, tools, progressive
   disclosure, hooks assembly, context reducer.

   Extracted from keeper_agent_run.ml. *)

open Keeper_types
open Keeper_agent_tool_surface
open Keeper_agent_result
open Keeper_agent_error
open Keeper_agent_prompt_metrics

(** Mutable accumulator for OAS hook callbacks.

    OAS hooks (before_turn, on_tool_executed) cannot return values, so
    they write into this single mutable record during Agent.run execution.
    After execution completes, {!freeze} produces an immutable snapshot. *)
type hook_accumulator =
  { mutable meta : Keeper_types.keeper_meta
  ; mutable tool_calls : tool_call_detail list
  ; mutable current_turn : int
  ; mutable completion_contract : Keeper_tool_disclosure.completion_contract
  ; mutable required_tool_use_seen : bool
  ; mutable keeper_surface_tool_used : bool
  ; mutable discovered : Keeper_discovered_tools.t
  ; mutable tool_overlay : Oas.Tool_op.t
  ; mutable tool_surface : tool_surface_metrics
  ; mutable requested_tool_names : string list
  ; mutable receipt_tool_contract_result : string
  }

(** Immutable snapshot of hook outputs after OAS execution completes. *)
type hook_outputs =
  { out_meta : Keeper_types.keeper_meta
  ; out_tool_calls : tool_call_detail list
  ; out_completion_contract : Keeper_tool_disclosure.completion_contract
  ; out_required_tool_use_seen : bool
  ; out_keeper_surface_tool_used : bool
  ; out_discovered : Keeper_discovered_tools.t
  ; out_tool_overlay : Oas.Tool_op.t
  ; out_tool_surface : tool_surface_metrics
  ; out_requested_tool_names : string list
  ; out_receipt_tool_contract_result : string
  }

val freeze : hook_accumulator -> hook_outputs

(** Agent setup produced by Step 7.

    Hook mutations flow through {!acc}, receipt refs are kept for
    facade post-processing writes, and [agent_ref] is created locally
    at the OAS call site. *)
type agent_setup =
  { tools : Oas.Tool.t list
  ; hooks : Oas.Hooks.hooks
  ; reducer : Oas.Context_reducer.t
  ; memory : Oas.Memory.t
  ; acc : hook_accumulator
  ; initial_tool_surface : computed_tool_surface
  ; initial_tool_surface_blocker : Oas.Error.sdk_error option ref
  ; all_tool_names : string list
  ; tool_usage_before : (string * int) list
  ; receipt_turn_count_ref : int option ref
  ; receipt_model_used_ref : string option ref
  ; receipt_stop_reason_ref : string option ref
  ; receipt_cascade_observation_ref : Oas_worker.cascade_observation option ref
  ; receipt_response_text_present_ref : bool ref
  ; reported_tool_names_ref : string list ref
  ; observed_tool_names_ref : string list ref
  ; canonical_tool_names_ref : string list ref
  ; unexpected_tool_names_ref : string list ref
  ; actual_keeper_tool_names_ref : string list ref
  }

val prepare_agent_setup :
     config:Coord.config
  -> meta:Keeper_types.keeper_meta
  -> ctx_work:working_context
  -> session:Keeper_types.session_context
  -> base_system_prompt:string
  -> turn_system_prompt:string
  -> user_message:string
  -> dynamic_context:string
  -> history_messages:Oas.Types.message list
  -> prompt_metrics:Keeper_agent_prompt_metrics.prompt_metrics
  -> shared_context:Oas.Context.t
  -> context_injector:Agent_sdk.Hooks.context_injector
  -> start_turn_count:int
  -> generation:int
  -> max_turns:int
  -> cascade_name:Keeper_cascade_profile.runtime_name
  -> is_retry:bool
  -> turn_affordances:string list
  -> config_root:string
  -> cascade_config_path:string option
  -> gemini_mcp_disabled:bool
  -> approval_mode_effective:string option
  -> approval_mode_derived:bool
  -> ?max_cost_usd:float
  -> trajectory_acc:Trajectory.accumulator option
  -> tool_overlay:Oas.Tool_op.t ref option
  -> unit
  -> (agent_setup, Oas.Error.sdk_error) result
