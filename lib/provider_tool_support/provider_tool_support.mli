(** AGENT_CORE provider capability projection used by MASC tool-lane selection. *)

type capabilities =
  { supports_inline_tools : bool
  ; supports_inline_tool_choice : bool
  }

type runtime_capabilities_override =
  { supports_inline_tools : bool option
  ; supports_inline_tool_choice : bool option
  }

val agent_core_capabilities_of_config :
  Llm_provider.Provider_config.t -> Llm_provider.Capabilities.capabilities
(** Return the AGENT_CORE-owned provider capability row without local reclassification. *)

val provider_supports_inline_tools :
  ?override:runtime_capabilities_override ->
  Llm_provider.Provider_config.t ->
  bool
