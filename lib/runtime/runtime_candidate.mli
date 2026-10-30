type t

val of_provider_config : Llm_provider.Provider_config.t -> t
val provider_cfg : t -> Llm_provider.Provider_config.t

val default_config :
  media_store:Agent_core.History.media_store ->
  name:string ->
  system_prompt:string ->
  tools:Agent_core.Tool.t list ->
  t ->
  Runtime_agent.config
