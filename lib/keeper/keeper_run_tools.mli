(* keeper_run_tools — Step 7 of run_turn: agent setup, tools, progressive
   disclosure, hooks assembly, context reducer.

   Extracted from keeper_agent_run.ml. *)

open Keeper_types
open Keeper_agent_tool_surface

(** All refs, tools, hooks, and reducer needed by Step 8 and post-processing. *)
type agent_setup =
  { tools : Oas.Tool.t list
  ; hooks : Oas.Hooks.hooks
  ; reducer : Oas.Context_reducer.t
  ; memory : Oas.Memory.t
  ; meta_ref : Keeper_types.keeper_meta ref
  ; agent_ref : Oas.Agent.t option ref
  ; initial_tool_surface : computed_tool_surface
  ; initial_tool_surface_blocker_ref : Oas.Error.sdk_error option ref
  ; tool_surface_ref : tool_surface_metrics ref
  ; tool_calls_ref : Keeper_agent_result.tool_call_detail list ref
  ; completion_contract_ref : Keeper_tool_disclosure.completion_contract ref
  ; required_tool_use_seen_ref : bool ref
  ; keeper_surface_tool_used_ref : bool ref
  ; discovered_ref : Keeper_discovered_tools.t ref
  ; tool_overlay_ref : Oas.Tool_op.t ref
  ; current_turn_ref : int ref
  ; all_tool_names : string list
  ; tool_usage_before : (string * int) list
  ; receipt_turn_count_ref : int option ref
  ; receipt_model_used_ref : string option ref
  ; receipt_stop_reason_ref : string option ref
  ; receipt_cascade_observation_ref : Oas_worker.cascade_observation option ref
  ; receipt_response_text_present_ref : bool ref
  ; receipt_tool_contract_result_ref : string ref
  ; requested_tool_names_ref : string list ref
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
  -> cascade_name:string
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
