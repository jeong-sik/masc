(** Wire-layer overlays applied after OAS resolves a provider config. *)

val apply :
  provider_cfg:Llm_provider.Provider_config.t ->
  Agent_sdk.Provider.config ->
  Agent_sdk.Provider.config

