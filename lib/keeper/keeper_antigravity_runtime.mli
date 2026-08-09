(** Keeper projection for one official Antigravity CLI turn. *)

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
  enable_thinking:bool option ->
  config:Runtime_execution.antigravity_cli ->
  (Runtime_agent.run_result, Agent_sdk.Error.sdk_error) result

(** Antigravity owns its built-in tool loop and does not expose a custom-tool
    transport in [agy --print]. Consequently this boundary rejects MASC tools,
    tool hooks, and context injection instead of silently dropping them. *)
