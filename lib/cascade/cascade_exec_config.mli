(** Cascade_exec_config — OAS execution config helpers.

    Kept separate from {!Cascade_error_classify} so the structured-error
    type stays a leaf dependency for keeper/accountability and worker paths. *)

val config_for_label :
  name:string ->
  model_label:string ->
  system_prompt:string ->
  tools:Agent_sdk.Tool.t list ->
  max_turns:int ->
  max_tokens:int ->
  ?max_input_tokens:int ->
  ?max_cost_usd:float ->
  temperature:float ->
  ?max_idle_turns:int ->
  ?stream_idle_timeout_s:float ->
  ?guardrails:Agent_sdk.Guardrails.t ->
  ?hooks:Agent_sdk.Hooks.hooks ->
  ?context_reducer:Agent_sdk.Context_reducer.t ->
  ?memory:Agent_sdk.Memory.t ->
  ?tool_retry_policy:Agent_sdk.Tool_retry_policy.t ->
  ?enable_thinking:bool ->
  ?compact_ratio:float ->
  ?contract:Masc_mcp_cdal_runtime.Risk_contract.t ->
  ?approval:Agent_sdk.Hooks.approval_callback ->
  description:string option ->
  unit ->
  (Cascade_runner.config, Agent_sdk.Error.sdk_error) result
(** Build a {!Cascade_runner.config} from a model label string. Resolves
    the provider config and fills in defaults. *)

type argv_prompt_preflight = {
  prompt_bytes : int;
  prompt_tokens : int;
  context_window_tokens : int;
  retry_limit_tokens : int;
  hits_argv_limit : bool;
  hits_context_window : bool;
}

val argv_prompt_preflight :
  config:Cascade_runner.config -> goal:string -> argv_prompt_preflight option
(** Check whether an argv-prompt transport would exceed argv or context-window
    limits. Returns [Some] when limits are hit, [None] when safe or when the
    provider adapter does not require argv preflight. *)

val with_argv_prompt_preflight :
  scope:string ->
  config:Cascade_runner.config ->
  goal:string ->
  (unit -> ('a, Agent_sdk.Error.sdk_error) result) ->
  ('a, Agent_sdk.Error.sdk_error) result
(** Wrap an execution with the provider adapter's argv prompt preflight. *)
