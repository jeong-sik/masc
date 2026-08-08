(** Keeper projection for the official Codex app-server turn runtime. *)

val run :
  runtime_id:string ->
  keeper_name:string ->
  base_path:string ->
  goal:string ->
  goal_blocks:Agent_sdk.Types.content_block list option ->
  system_prompt:string ->
  tools:Agent_sdk.Tool.t list ->
  initial_messages:Agent_sdk.Types.message list ->
  model_input_projection:Agent_sdk.Agent.model_input_projection option ->
  hooks:Agent_sdk.Hooks.hooks option ->
  context_injector:Agent_sdk.Hooks.context_injector option ->
  context:Agent_sdk.Context.t option ->
  event_bus:Agent_sdk.Event_bus.t option ->
  enable_thinking:bool option ->
  config:Runtime_execution.codex_app_server ->
  (Runtime_agent.run_result, Agent_sdk.Error.sdk_error) result
