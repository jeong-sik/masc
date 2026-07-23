type t

val of_provider_config : Llm_provider.Provider_config.t -> t
val of_provider_configs : Llm_provider.Provider_config.t list -> t list

val provider_cfg : t -> Llm_provider.Provider_config.t

val model_health_key : t -> string
val default_config :
  name:string ->
  system_prompt:string ->
  tools:Agent_sdk.Tool.t list ->
  t ->
  Runtime_agent.config
