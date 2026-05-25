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
  ; mutable tool_overlay : Agent_sdk.Tool_op.t
  ; mutable tool_surface : tool_surface_metrics
  ; mutable requested_tool_names : string list
  ; mutable requested_tool_names_seen : string list
  ; mutable receipt_tool_contract_result :
      Keeper_execution_receipt.tool_contract_result
  ; mutable contract_violation_retries : int
  }

(** Immutable snapshot of hook outputs after OAS execution completes. *)
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

val merge_requested_tool_names_seen
  :  seen:string list
  -> string list
  -> string list

type tool_search_hit_partition =
  { visible_core_hits : (string * float) list
  ; discoverable_hits : (string * float) list
  ; filtered_by_policy : int
  }

val partition_tool_search_hits
  :  core:string list
  -> core_always:string list
  -> allowed:string list
  -> retrieved:(string * float) list
  -> max_results:int
  -> tool_search_hit_partition

val truncate_tool_surface_names
  :  max_tools:int
  -> essential_names:string list
  -> string list
  -> string list
(** Keep essential tools at the front while truncating an already ordered
    visible tool surface. Essential names are removed from the tail before the
    budget slice so required/affordance tools cannot be double-counted. *)

(** Agent setup produced by Step 7.

    Hook mutations flow through {!acc}, receipt refs are kept for
    facade post-processing writes, and [agent_ref] is created locally
    at the OAS call site. *)
type agent_setup = Keeper_run_tools_hooks.agent_setup

val prepare_agent_setup
  :  config:Coord.config
  -> meta:Keeper_types.keeper_meta
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
  -> max_turns:int
  -> cascade_name:Cascade_name.t
  -> is_retry:bool
  -> turn_affordances:string list
  -> required_tool_names:string list
  -> config_root:string
  -> cascade_config_path:string option
  -> gemini_mcp_disabled:bool
  -> approval_mode_effective:string option
  -> approval_mode_derived:bool
  -> ?actionable_signal:bool
  -> ?max_cost_usd:float
  -> trajectory_acc:Trajectory.accumulator option
  -> tool_overlay:Agent_sdk.Tool_op.t ref option
  -> ?runtime_manifest_context:Keeper_runtime_manifest.turn_context
  -> ?runtime_manifest_append:(Keeper_runtime_manifest.t -> unit)
  -> unit
  -> (agent_setup, Agent_sdk.Error.sdk_error) result
