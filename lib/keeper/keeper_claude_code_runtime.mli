(** Keeper projection for the official Claude Code CLI turn runtime.

    Claude Code owns its built-in tool loop. This boundary deliberately does
    not project MASC tools, Gate callbacks, or OAS checkpoints into that loop. *)

val run :
  runtime_id:string ->
  keeper_name:string ->
  base_path:string ->
  goal:string ->
  goal_blocks:Agent_sdk.Types.content_block list option ->
  system_prompt:string ->
  initial_messages:Agent_sdk.Types.message list ->
  model_input_projection:Agent_sdk.Agent.model_input_projection option ->
  hooks:Agent_sdk.Hooks.hooks option ->
  on_runtime_observation:(Runtime_observation.runtime_observation -> unit) option ->
  config:Runtime_execution.claude_code ->
  (Runtime_agent.run_result, Agent_sdk.Error.sdk_error) result
