(** AGENT_CORE provider capability projection used by MASC tool-lane selection. *)

val agent_core_capabilities_of_config :
  Llm_provider.Provider_config.t -> Llm_provider.Capabilities.capabilities
(** Return the AGENT_CORE-owned provider capability row without local reclassification. *)

val provider_supports_inline_tools : Llm_provider.Provider_config.t -> bool
(** The row's [supports_tools]: whether the provider accepts inline tool
    definitions on a request. *)
