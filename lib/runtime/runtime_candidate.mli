type t

val of_provider_config : Llm_provider.Provider_config.t -> t
val provider_cfg : t -> Llm_provider.Provider_config.t

val selected_endpoint_label : t -> string
(** Which provider, model and endpoint this candidate resolves to, for
    reporting a completed turn. *)
val default_config :
  name:string ->
  system_prompt:string ->
  tools:Agent_core.Tool.t list ->
  t ->
  Runtime_agent.config
