(** Keeper single-turn orchestration via OAS Agent.run().

    This module is intentionally a compatibility facade: public types and
    entrypoints stay here while prompt metrics, result/error helpers, and
    tool-surface policy live in focused implementation modules. *)

include module type of Keeper_agent_prompt_metrics
include module type of Keeper_agent_tool_surface
include module type of Keeper_agent_result
include module type of Keeper_agent_error
include module type of Keeper_agent_checkpoint_hygiene

module Contract_helpers = Keeper_agent_run_contract_helpers
module Turn_helpers = Keeper_agent_run_turn_helpers

val should_require_provider_tool_choice_support
  :  initial_tool_requirement:tool_requirement
  -> actionable_observation_requires_tool_support:bool
  -> bool

val tool_contract_result_for_observed_tools
  :  required_tool_names:string list
  -> missing_visible_required:string list
  -> had_owned_active_task_at_turn_start:bool
  -> actual_keeper_tool_names:string list
  -> Keeper_execution_receipt.tool_contract_result

module For_testing : sig
  val sse_event_progress_kind : Agent_sdk.Types.sse_event -> string option
  val registry_progress_on_event
    :  record_turn_progress:(string -> unit)
    -> (Agent_sdk.Types.sse_event -> unit) option
    -> Agent_sdk.Types.sse_event
    -> unit
  val select_cdal_proof
    :  result_proof:Masc_mcp_cdal_runtime.Cdal_proof.t option
    -> captured_proof:Masc_mcp_cdal_runtime.Cdal_proof.t option
    -> Masc_mcp_cdal_runtime.Cdal_proof.t option
  val cdal_task_id_for_verdict
    :  current_task_id:string option
    -> tool_calls:tool_call_detail list
    -> string option
  val cdal_verdict_persist_decision
    :  string option
    -> [> `Persist_task_scoped of string | `Skip_missing_task_scope ]
  val progress_keeper_tool_names_for_contract
    :  allowed_tool_names:string list
    -> actual_keeper_tool_names:string list
    -> tool_calls:tool_call_detail list
    -> string list
  val no_progress_success_tool_names_for_contract
    :  allowed_tool_names:string list
    -> tool_calls:tool_call_detail list
    -> string list
end

val per_provider_timeout_for_turn
  :  meta:Keeper_types.keeper_meta
  -> ?oas_timeout_s:float
  -> ?oas_timeout_is_explicit:bool
  -> timeout_s:float
  -> unit
  -> float option

(** {1 Turn execution} *)

(** Run a single keeper turn.

    @param config Coord configuration
    @param meta Keeper metadata
    @param base_dir Session base directory for checkpoints
    @param max_context Maximum context window tokens
    @param build_turn_prompt Callback: receives the base keeper system prompt
           and checkpoint message history, returns the final turn system prompt
    @param user_message The user's message to the keeper
    @param cascade_name Typed runtime cascade profile name for model selection
    @param world_observation Structured keeper world snapshot used by
           required-tool contract checks. When omitted, the contract gate
           does not infer world state from prompt text.
    @param provider_filter Optional provider restriction
    @param generation Current generation counter
    @param max_turns Maximum agent turns (default from env config)
    @param max_idle_turns Maximum consecutive idle turns before stop
    @param history_user_source Source label for user messages in history
    @param history_assistant_source Source label for assistant messages in history
    @param guardrails Optional OAS guardrails for tool safety gates
    @param temperature MODEL temperature override
    @param max_tokens Maximum output tokens override
    @param max_cost_usd Maximum cost per turn in USD
    @param on_event Optional event callback
    @param trajectory_acc Optional trajectory accumulator for recording
    @param tool_overlay Optional mutable tool overlay for dynamic tools
    @param priority Optional priority for scheduling
    @param is_retry When [true], replays current user message without persisting
    @param shared_context Optional shared OAS context for cross-turn state
    @param event_bus Optional MASC event bus *)
val run_turn
  :  config:Coord.config
  -> meta:Keeper_types.keeper_meta
  -> base_dir:string
  -> max_context:int
  -> build_turn_prompt:
       (base_system_prompt:string -> messages:Agent_sdk.Types.message list -> turn_prompt)
  -> user_message:string
  -> cascade_name:Cascade_name.t
  -> ?world_observation:Keeper_world_observation.world_observation
  -> ?turn_affordances:string list
  -> ?required_tool_names:string list
  -> ?provider_filter:string list
  -> generation:int
  -> ?max_turns:int
  -> ?max_idle_turns:int
  -> ?history_user_source:string
  -> ?history_assistant_source:string
  -> ?guardrails:Agent_sdk.Guardrails.t
  -> ?temperature:float
  -> ?max_tokens:int
  -> ?oas_timeout_s:float
  -> ?oas_timeout_is_explicit:bool
  -> ?max_cost_usd:float
  -> ?on_event:(Agent_sdk.Types.sse_event -> unit)
  -> ?trajectory_acc:Trajectory.accumulator
  -> ?tool_overlay:Agent_sdk.Tool_op.t ref
  -> ?priority:Llm_provider.Request_priority.t
  -> ?degraded_retry_applied:bool
  -> ?degraded_retry_cascade:string
  -> ?fallback_reason:Keeper_error_classify.degraded_retry_reason
  -> ?cascade_rotation_attempts:Keeper_execution_receipt.cascade_rotation_attempt list
  -> ?is_retry:bool
  -> ?shared_context:Agent_sdk.Context.t
  -> ?event_bus:Agent_sdk.Event_bus.t
  -> unit
  -> (run_result, Agent_sdk.Error.sdk_error) result
