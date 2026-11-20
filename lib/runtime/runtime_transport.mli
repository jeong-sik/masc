(** Runtime_transport — capability helpers for AGENT_CORE worker execution. *)

(** AGENT_CORE capability snapshot for a provider config.  Alias for
    {!Provider_tool_support.agent_core_capabilities_of_config}. *)
val provider_caps_of_config :
  Llm_provider.Provider_config.t -> Llm_provider.Capabilities.capabilities

(** Whether a provider can accept inline tool definitions on a request.
    Alias for {!Provider_tool_support.provider_supports_inline_tools}. *)
val provider_supports_inline_tools : Llm_provider.Provider_config.t -> bool

(** Human-readable [provider_kind:model_id] label. *)
val provider_label : Llm_provider.Provider_config.t -> string

(* Provider dispatch is HTTP-only. *)
