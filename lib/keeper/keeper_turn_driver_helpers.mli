(** Pure helpers extracted from [Keeper_turn_driver].

    See [.ml] for rationale. No behavior change from pre-RFC-0048 inline
    definitions. *)

val provider_health_keys_of_config :
  Llm_provider.Provider_config.t -> string list

val first_health_cooldown :
  Llm_provider.Provider_config.t -> (string * string) option

type provider_attempt_timeout_constraints = {
  min_timeout_s : float option;
  max_timeout_s : float option;
}

val provider_attempt_timeout_constraints :
  Llm_provider.Provider_config.t -> provider_attempt_timeout_constraints

val apply_provider_attempt_timeout_constraints :
  provider_attempt_timeout_constraints -> float -> float

val provider_default_attempt_timeout_s :
  provider_attempt_timeout_constraints -> float option

val effective_provider_attempt_timeout_s :
  is_last:bool ->
  configured_timeout_s:float option ->
  Llm_provider.Provider_config.t ->
  float option

val required_tool_names_for_no_tool_error :
  runtime_mcp_policy:Llm_provider.Llm_transport.runtime_mcp_policy option ->
  tools:Agent_sdk.Tool.t list ->
  string list

val provider_rejections_for_no_tool_error :
  keeper_name:string ->
  ?runtime_mcp_policy:Llm_provider.Llm_transport.runtime_mcp_policy ->
  tools:Agent_sdk.Tool.t list ->
  require_tool_choice_support:bool ->
  require_tool_support:bool ->
  Llm_provider.Provider_config.t list ->
  Cascade_error_classify.provider_rejection list

val apply_stream_idle_timeout_default : float option -> float option

val checkpoint_after_attempt :
  ?agent_ref:Agent_sdk.Agent.t option ref ->
  Agent_sdk.Agent.t option ->
  Agent_sdk.Checkpoint.t option
