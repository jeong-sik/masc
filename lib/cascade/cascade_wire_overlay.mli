(** Wire-layer overlays applied after OAS resolves a provider config. *)

val auth_header_authorization : string

val apply :
  provider_cfg:Llm_provider.Provider_config.t ->
  Agent_sdk.Provider.config ->
  Agent_sdk.Provider.config

